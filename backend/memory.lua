local time = require "silly.time"
local json = require "silly.encoding.json"
local logger = require "silly.logger"
local mutex = require "silly.sync.mutex"
local silly = require "silly"
local task = require "silly.task"
local conf = require "conf"
local openai = require "openai"

local M = {}
local mt = {__index = M}

local summary_lock = mutex.new()

local state = {
	inited = false,
	logs = {},
	unsaved = {},
	sessions = {},
	session_meta = {},
	summary = "",
	last_activity = 0,
	summary_worker_running = false,
	flush_worker_running = false,
	summary_count = 0,
	config = {},
}

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return ""
	end
	local content = f:read("a")
	f:close()
	return content or ""
end

local function write_file(path, content)
	local f, err = io.open(path, "w")
	if not f then
		logger.errorf("[memory] write file failed: %s", err)
		return false
	end
	f:write(content or "")
	f:close()
	return true
end

local function append_lines(path, lines)
	if #lines == 0 then
		return true
	end
	local f, err = io.open(path, "a")
	if not f then
		logger.errorf("[memory] append file failed: %s", err)
		return false
	end
	for _, line in ipairs(lines) do
		f:write(line, "\n")
	end
	f:close()
	return true
end

local function decode_lines(lines)
	local entries = {}
	for _, line in ipairs(lines) do
		if #line > 0 then
			local ok, obj = pcall(json.decode, line)
			if ok and obj then
				entries[#entries + 1] = obj
			end
		end
	end
	return entries
end

local function estimate_tokens(text)
	if not text or #text == 0 then
		return 0
	end
	local ascii = 0
	local non_ascii = 0
	local i = 1
	local len = #text
	while i <= len do
		local c = text:byte(i)
		if c < 128 then
			ascii = ascii + 1
			i = i + 1
		elseif c < 224 then
			non_ascii = non_ascii + 1
			i = i + 2
		elseif c < 240 then
			non_ascii = non_ascii + 1
			i = i + 3
		else
			non_ascii = non_ascii + 1
			i = i + 4
		end
	end
	local est = math.ceil(ascii / 4) + non_ascii
	return est
end

local function load_config()
	local history_conf = conf.history or {}
	state.config = {
		log_file = history_conf.log_file or "data/chat.jsonl",
		summary_file = history_conf.summary_file or "data/summary.txt",
		archive_file = history_conf.archive_file or "data/chat_archive.jsonl",
		silence_seconds = history_conf.silence_seconds or 60,
		recent_rounds = history_conf.recent_rounds or 500,
		session_context_max_messages = history_conf.session_context_max_messages or 100,
		context_max_tokens = history_conf.context_max_tokens or 2000,
		cleanup_max_entries = history_conf.cleanup_max_entries or 5000,
		cleanup_max_days = history_conf.cleanup_max_days or 30,
		flush_interval_seconds = history_conf.flush_interval_seconds or 10,
		summary_rewrite_every = history_conf.summary_rewrite_every or 20,
	}
end

local function ensure_init()
	if state.inited then
		return
	end
	load_config()
	state.summary = read_file(state.config.summary_file)
	local f = io.open(state.config.log_file, "r")
	if f then
		for line in f:lines() do
			if #line > 0 then
				local ok, obj = pcall(json.decode, line)
				if ok and obj then
					state.logs[#state.logs + 1] = obj
					local sid = obj.session_id or ""
					if #sid > 0 then
						local s = state.sessions[sid]
						if not s then
							s = {history = {}}
							state.sessions[sid] = s
						end
						s.history[#s.history + 1] = {role = obj.role, content = obj.content}
						local meta = state.session_meta[sid]
						if not meta then
							meta = {session_id = sid, count = 0, last_ts = 0}
							state.session_meta[sid] = meta
						end
						meta.count = meta.count + 1
						meta.last_ts = math.max(meta.last_ts, obj.ts or 0)
					end
				end
			end
		end
		f:close()
	end
	state.inited = true
	if not state.flush_worker_running then
		state.flush_worker_running = true
		task.fork(function()
			while true do
				time.sleep(state.config.flush_interval_seconds)
				if #state.unsaved > 0 then
					append_lines(state.config.log_file, state.unsaved)
					state.unsaved = {}
				end
			end
		end)
	end
end

local function build_recent_entries()
	local needed_rounds = state.config.recent_rounds
	local entries = {}
	local rounds = 0
	for i = #state.logs, 1, -1 do
		local e = state.logs[i]
		entries[#entries + 1] = e
		if e.role == "assistant" then
			rounds = rounds + 1
			if rounds >= needed_rounds then
				break
			end
		end
	end
	local out = {}
	for i = #entries, 1, -1 do
		out[#out + 1] = entries[i]
	end
	return out
end

local function postprocess_summary(text)
	if not text or #text == 0 then
		return ""
	end
	local lines = {}
	for line in text:gmatch("[^\r\n]+") do
		local cleaned = line:gsub("%s+$", "")
		if #cleaned > 0 then
			lines[#lines + 1] = cleaned
		end
	end
	local seen = {}
	local out = {}
	for _, line in ipairs(lines) do
		local key = line:gsub("%s+", " "):lower()
		if not seen[key] then
			seen[key] = true
			out[#out + 1] = line
		end
	end
	return table.concat(out, "\n")
end

local function update_summary(rewrite)
	local entries = build_recent_entries()
	if #entries == 0 then
		return
	end
	local prev_summary = state.summary or ""
	local system_prompt = [[
你是对话历史的整理员，需要把多轮对话压缩成高质量的长期总结。
要求：
1. 只保留重要事实、明确需求、已达成共识、长期偏好。
2. 忽略寒暄、重复、无效内容。
3. 总结必须简洁，强调更重要的事情。
4. 允许在已有总结上更新或修正。
输出请使用简洁的分段文本，不要输出 JSON，不要加入任何解释。
]]
	if rewrite then
		system_prompt = [[
你是对话历史的整理员，请基于已有总结与最近对话，重新整理出更干净、更准确的长期总结。
要求：
1. 去重、去噪、纠错，突出最重要的信息。
2. 保留长期偏好、关键事实、明确需求、已达成共识。
3. 文字要简洁、结构清晰。
输出请使用简洁的分段文本，不要输出 JSON，不要加入任何解释。
]]
	end
	local messages = {
		{
			role = "system",
			content = system_prompt
		},
		{
			role = "user",
			content = string.format("已有总结：\n%s\n\n最近对话记录（JSON 数组）：\n%s\n\n请输出更新后的总结。", prev_summary, json.encode(entries))
		},
	}
	local model_conf = conf.llm and conf.llm.think
	if not model_conf then
		logger.error("[memory] think model not configured")
		return
	end
	local ai<close>, err = openai.open(model_conf, {
		messages = messages,
		temperature = 0.1,
		top_p = 0.3,
		frequency_penalty = 0.3,
	})
	if not ai then
		logger.errorf("[memory] summary failed: %s", err)
		return
	end
	local response, err = ai:read()
	if not response then
		logger.errorf("[memory] summary read failed: %s", err)
		return
	end
	local content = response.choices[1].message.content or ""
	if #content > 0 then
		content = postprocess_summary(content)
		state.summary = content
		write_file(state.config.summary_file, content)
	end
end

local function cleanup_logs()
	if #state.logs == 0 then
		return
	end
	local now = os.time()
	local cutoff = now - state.config.cleanup_max_days * 24 * 60 * 60
	local keep = {}
	local archive = {}
	local keep_recent_start = math.max(1, #state.logs - (state.config.recent_rounds * 2) + 1)
	for i, entry in ipairs(state.logs) do
		if i >= keep_recent_start then
			keep[#keep + 1] = entry
		else
			local ts = entry.ts
			if state.config.cleanup_max_days > 0 and ts and ts >= cutoff then
				keep[#keep + 1] = entry
			else
				archive[#archive + 1] = entry
			end
		end
	end
	if state.config.cleanup_max_entries > 0 and #keep > state.config.cleanup_max_entries then
		local overflow = #keep - state.config.cleanup_max_entries
		for i = 1, overflow do
			archive[#archive + 1] = keep[i]
		end
		local new_keep = {}
		for i = overflow + 1, #keep do
			new_keep[#new_keep + 1] = keep[i]
		end
		keep = new_keep
	end
	if #archive > 0 then
		local lines = {}
		for i = 1, #archive do
			lines[i] = json.encode(archive[i])
		end
		append_lines(state.config.archive_file, lines)
	end
	state.logs = keep
	local lines = {}
	for i = 1, #keep do
		lines[i] = json.encode(keep[i])
	end
	write_file(state.config.log_file, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

local function schedule_summary()
	state.last_activity = time.now() // 1000
	if state.summary_worker_running then
		return
	end
	state.summary_worker_running = true
	task.fork(function()
		while true do
			time.sleep(state.config.silence_seconds)
			local now = time.now() // 1000
			if now - state.last_activity >= state.config.silence_seconds then
				local lock<close> = summary_lock:lock("summary")
				if #state.unsaved > 0 then
					append_lines(state.config.log_file, state.unsaved)
					state.unsaved = {}
				end
				local rewrite = false
				if state.config.summary_rewrite_every > 0 and state.summary_count > 0 then
					rewrite = (state.summary_count % state.config.summary_rewrite_every == 0)
				end
				update_summary(rewrite)
				state.summary_count = state.summary_count + 1
				cleanup_logs()
				state.summary_worker_running = false
				return
			end
		end
	end)
end

function M.init()
	ensure_init()
	return true
end

function M.reload_conf()
	load_config()
end

function M.reload_logs()
	ensure_init()
	state.logs = {}
	state.sessions = {}
	state.session_meta = {}
	state.unsaved = {}
	local f = io.open(state.config.log_file, "r")
	if not f then
		return
	end
	for line in f:lines() do
		if #line > 0 then
			local ok, obj = pcall(json.decode, line)
			if ok and obj then
				state.logs[#state.logs + 1] = obj
				local sid = obj.session_id or ""
				if #sid > 0 then
					local s = state.sessions[sid]
					if not s then
						s = {history = {}}
						state.sessions[sid] = s
					end
					s.history[#s.history + 1] = {role = obj.role, content = obj.content}
					local meta = state.session_meta[sid]
					if not meta then
						meta = {session_id = sid, count = 0, last_ts = 0}
						state.session_meta[sid] = meta
					end
					meta.count = meta.count + 1
					meta.last_ts = math.max(meta.last_ts, obj.ts or 0)
				end
			end
		end
	end
	f:close()
end

function M.get_summary()
	ensure_init()
	return state.summary or ""
end

function M.set_summary(text)
	ensure_init()
	state.summary = text or ""
	write_file(state.config.summary_file, state.summary)
end

---@param uid number
---@param session_id string
---@return memory
function M.new(uid, session_id)
	ensure_init()
	local sid = session_id or tostring(uid)
	if not state.sessions[sid] then
		state.sessions[sid] = {history = {}}
	end
	if not state.session_meta[sid] then
		state.session_meta[sid] = {session_id = sid, count = 0, last_ts = 0}
	end
	return setmetatable({
		uid = uid,
		session_id = sid,
		session_no = 1,
		seq = 0,
	}, mt)
end

---@param self memory
---@param tbl table{role: string, content: string}
---@param msg string
function M:retrieve(tbl, msg)
	ensure_init()
	local max_tokens = state.config.context_max_tokens
	local summary = state.summary
	local used = 0
	if summary and #summary > 0 then
		local sum_tokens = estimate_tokens(summary)
		used = used + sum_tokens
		tbl[#tbl + 1] = {
			role = "system",
			content = "历史总结：\n" .. summary,
		}
	end
	local s = state.sessions[self.session_id]
	local history = s and s.history or {}
	local max_msgs = state.config.session_context_max_messages
	local added = 0
	local buf = {}
	for i = #history, 1, -1 do
		local item = history[i]
		local t = estimate_tokens(item.content)
		if used + t > max_tokens then
			break
		end
		buf[#buf + 1] = item
		used = used + t
		added = added + 1
		if added >= max_msgs then
			break
		end
	end
	for i = #buf, 1, -1 do
		tbl[#tbl + 1] = buf[i]
	end
	tbl[#tbl + 1] = {
		role = "user",
		content = msg,
	}
end

local function add_entry(self, role, content)
	local entry = {
		ts = os.time(),
		uid = self.uid,
		session_id = self.session_id,
		session_no = self.session_no,
		seq = self.seq,
		role = role,
		content = content,
	}
	state.logs[#state.logs + 1] = entry
	state.unsaved[#state.unsaved + 1] = json.encode(entry)
	local s = state.sessions[self.session_id]
	if s then
		s.history[#s.history + 1] = {role = role, content = content}
	end
	local meta = state.session_meta[self.session_id]
	if not meta then
		meta = {session_id = self.session_id, count = 0, last_ts = 0}
		state.session_meta[self.session_id] = meta
	end
	meta.count = meta.count + 1
	meta.last_ts = math.max(meta.last_ts, entry.ts or 0)
end

function M:add(q, a)
	ensure_init()
	self.seq = self.seq + 1
	add_entry(self, "user", q)
	self.seq = self.seq + 1
	add_entry(self, "assistant", a)
	schedule_summary()
end

function M:close()
	schedule_summary()
end

function M.list_sessions()
	ensure_init()
	local out = {}
	for _, meta in pairs(state.session_meta) do
		out[#out + 1] = {
			session_id = meta.session_id,
			count = meta.count,
			last_ts = meta.last_ts,
		}
	end
	table.sort(out, function(a, b)
		return (a.last_ts or 0) > (b.last_ts or 0)
	end)
	return out
end

function M.get_session_history(session_id, max_messages, max_tokens)
	ensure_init()
	if not session_id or #session_id == 0 then
		return {}
	end
	local max_msgs = max_messages or 100
	local max_toks = max_tokens or state.config.context_max_tokens
	local used = 0
	local added = 0
	local buf = {}
	for i = #state.logs, 1, -1 do
		local e = state.logs[i]
		if e.session_id == session_id then
			local t = estimate_tokens(e.content)
			if used + t > max_toks then
				break
			end
			buf[#buf + 1] = e
			used = used + t
			added = added + 1
			if added >= max_msgs then
				break
			end
		end
	end
	local out = {}
	for i = #buf, 1, -1 do
		local e = buf[i]
		out[#out + 1] = {
			ts = e.ts,
			role = e.role,
			content = e.content,
		}
	end
	return out
end

return M
