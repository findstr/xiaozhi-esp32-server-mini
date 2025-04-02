local core = require "core"
local time = require "core.time"
local json = require "core.json"
local logger = require "core.logger"
local openai = require "openai"
local embedding = require "embedding"
local db = require "db"

local tonumber = tonumber
local date = os.date
local format = string.format
local concat = table.concat
local tremove = table.remove

---@class memory
---@field uid number
---@field working {role: string, content: string}[]
---@field compressed string[]
---@field summary string
---@field profile string
---@field private modify_version number
---@field private process_version number
---@field private update_time number
local M = {}
local mt = {__index = M}

local dbk_user<const> = "user:%s"
local dbk_mem<const>  = "mem:%s"
local memory_index_name<const> = "memory_idx"
local dbk_mem_id = time.now() * 1000
local keep_converse_count<const> = 5

local function newuser(uid, profile)
	return {
		modify_version = 1,
		process_version = 1,
		uid = uid,
		working = {},
		compressed = {},
		profile = profile,
		update_time = time.nowsec(),
	}
end

local memory_cache = setmetatable({}, {
	__mode = "v",
	__index = function(t, k)
		local u
		local ok, v = db:call("JSON.GET", format(dbk_mem, k))
		if ok and v then
			u = json.decode(v)
		end
		if not u then
			u = newuser(k, "")
		end
		setmetatable(u, mt)
		t[k] = u
		return u
	end
})

-- 等待后处理的记忆
local opening_memory = {}
local closing_memory = {}
local wait_for_thinking = {}

local function create_index()
	-- check index if exists
	local ok, res = db:call("FT.INFO", memory_index_name)
	if ok then
		logger.infof("[memory] index %s already exists", memory_index_name)
		return true
	end
	-- create vector index
	local ok, err = db:call("FT.CREATE", memory_index_name, "ON", "HASH",
		"PREFIX", "1", "mem:",
		"SCHEMA",
			"uid", "TAG",
			"timestamp", "NUMERIC", "SORTABLE",
			"embedding", "VECTOR", "HNSW", "6",
			"TYPE", "FLOAT32",
			"DIM", "1024",
			"DISTANCE_METRIC", "COSINE")
	if not ok then
		logger.errorf("[memory] create index failed: %s", err)
		return false
	end
	logger.infof("[memory] create index success")
	return true
end

local function retrieval(uid, msg)
	local vector, err = embedding(msg)
	if not vector then
		logger.errorf("[memory] uid:%s embedding failed: %s", uid, err)
		return nil, err
	end
	local ok, res = db:call("FT.SEARCH",
		memory_index_name,
		"@uid:{$uid}=>[KNN $n @embedding $vector as score]",
		"PARAMS", "6",
		"n", 5,
		"vector", vector,
		"uid", uid,
		"SORTBY", "timestamp", "DESC",
		"RETURN", "3",
		"chk_id", "score", "text",
		"DIALECT", "2"
	)
	if not ok then
		logger.errorf("[memory] uid:%s search failed: %s", uid, res)
		return nil, err
	end
	if not res or #res < 2 then
		return nil, "no result"
	end
	local results = {
		"以下是与当前查询相关的过去会话记忆："
	}
	for i=2, #res, 2 do
		local r = {}
		local dbv = res[i+1]
		for j = 1, #dbv, 2 do
			local k = dbv[j]
			local v = dbv[j+1]
			r[k] = v
		end
		local score = 1.0 - tonumber(r.score)
		results[#results+1] = format("[相关性: %.2f | 时间: %s] %s",
			score, date("%Y-%m-%d %H:%M:%S", r.timestamp), r.text)
	end
	return concat(results, "\n\n"), nil
end

local function compress(messages)
	local prompt = {{
		role = "system",
		content = [[请对以下对话片段进行轻度压缩，保留关键信息和主要内容，但可以去除冗余细节。保持信息的完整性和准确性。]]
	}}
	for i = 1, #messages do
		prompt[#prompt+1] = messages[i]
	end
	local ai<close>, err = openai.open {
		messages = prompt,
		temperature = 0.3,
		llm = "think",
	}
	if not ai then
		return nil, err
	end
	local response = ai:read()
	if not response then
		return nil, "no response"
	end
	return response.choices[1].message.content
end

local function summarize(uid, summary, working)
	local all_context = {}
	all_context[#all_context+1] = {
		role = "system",
		content = [[
# 对话记忆整合指令
作为信息整合专家，请从对话中提取关键信息形成长期记忆。
严格按照指定格式输出，禁止添加任何分析、评论、问题或其他内容。

<输出格式>
主题: [核心讨论话题，1-2句概括]
需求: [用户明确表达的需求和问题，要点形式]
结论: [达成的共识和结论，要点形式]
偏好: [用户表达的明确偏好，要点形式]
待办: [未解决问题和后续行动项，要点形式]
其他: [任何不属于上述类别但重要的信息]
</输出格式>
]]
	}
	if summary and #summary > 0 then
		all_context[#all_context+1] = {
			role = "system",
			content = format("早期对话摘要：%s", summary),
		}
	end
	for i = 1, #working do
		all_context[#all_context+1] = working[i]
	end
	if #all_context == 0 then
		return ""
	end
	local ai<close>, err = openai.open {
		messages = all_context,
		temperature = 0.1, -- 更低的温度提高确定性
		top_p = 0.3,       -- 限制采样范围
		frequency_penalty = 0.5, -- 降低重复
		llm = "think",
	}
	if not ai then
		logger.errorf("[memory] update_summary uid:%s failed: %s", uid, err)
		return ""
	end
	local response, err = ai:read()
	if not response then
		logger.errorf("[memory] update_summary uid:%s failed: %s", uid, err)
		return ""
	end
	return response.choices[1].message.content
end

local function update_profile(profile, working)
	local all_context = {}
	all_context[#all_context+1] = {
		role = "system",
		content = [[
# 用户画像生成器
分析当前对话内容并更新用户画像。如果本次对话没有新的信息，请完整保留原有画像内容不变。
禁止添加任何其他回复或问题。
仅输出以下格式内容：

<用户画像>
兴趣: [列出兴趣点，无新信息则保持原列表]
职业: [职业信息，无新信息则保持原信息]
需求: [主要需求，无新信息则保持原需求]
偏好: [使用偏好，无新信息则保持原偏好]
背景: [相关背景，无新信息则保持原背景]
</用户画像>
]]
	}
	all_context[#all_context+1] = {
		role = "system",
		content = format("用户当前画像：%s", profile),
	}
	for i = 1, #working do
		all_context[#all_context+1] = working[i]
	end
	local ai<close>, err = openai.open {
		messages = all_context,
		temperature = 0.0, -- 降至最低以获得最大确定性
		top_p = 0.1, -- 进一步限制采样范围
		frequency_penalty = 0.3, -- 略微降低，因为过高可能导致避开必要的格式词
		presence_penalty = 0.1, -- 添加轻微的惩罚以避免引入新主题
		llm = "think",
		max_tokens = 150 -- 限制输出长度，只需要画像部分
	}
	if not ai then
		logger.errorf("[memory] update_profile failed: %s", err)
		return
	end
	local response, err = ai:read()
	if not response then
		logger.errorf("[memory] update_profile failed: %s", err)
		return
	end
	local content = response.choices[1].message.content
	return content
end

local function background_thinking()
	if #wait_for_thinking == 0 then
		for m, _ in pairs(opening_memory) do
			if closing_memory[m] then -- 如果正在关闭，需要清空
				closing_memory[m] = nil
				opening_memory[m] = nil
			end
			if m.modify_version > m.process_version then -- 没有修改，则不处理
				wait_for_thinking[#wait_for_thinking+1] = m
			end
		end
	end
	local mem = tremove(wait_for_thinking, 1)
	if not mem then
		core.timeout(1000, background_thinking)
		return
	end
	local modify_version = mem.modify_version
	local working = mem.working
	local profile = update_profile(mem.profile, working)
	if profile then
		mem.profile = profile
		logger.debugf("[memory] update_profile uid:%s profile: %s", mem.uid, profile)
	end
	if #working > keep_converse_count then
		local tmp = {}
		for i = keep_converse_count , #working do
			tmp[#tmp+1] = working[i]
			working[i] = nil
		end
		local context, err = compress(working)
		local summary = summarize(mem.uid, mem.summary, working)
		if not context then
			logger.errorf("[memory] compress_messages uid:%s failed: %s", mem.uid, err)
		else
			local t = mem.compressed
			t[#t+1] = context
		end
		working = tmp
		mem.working = working
		if summary then
			mem.summary = summary
		end
	end
	local now = time.nowsec() - 10 * 60 -- 10分钟内不更新
	local compressed = mem.compressed
	if #compressed > 10 or now > mem.update_time then -- 超过50条对话就认为是新的一轮对话
		local summary = summarize(mem.uid, mem.summary, working)
		if summary then
			mem.summary = summary
		end
		local ok, err = db:call("JSON.SET", format(dbk_user, mem.uid), "$", json.encode(mem))
		if not ok then
			logger.errorf("[memory] update_profile uid:%s failed: %s", mem.uid, err)
		end
		local summary = mem.summary
		local vector, err = embedding(summary)
		if not vector then
			logger.errorf("[memory] close uid:%s failed: %s", mem.uid, err)
			return
		end
		local session_id = dbk_mem_id + 1
		dbk_mem_id = session_id
		local dbk = format(dbk_mem, session_id)
		local ok, err = db:pipeline {
			{"HMSET", dbk,
				"uid", mem.uid,
				"embedding", vector,
				"text", summary,
				"timestamp", os.time()
			},
			{"EXPIRE", dbk, 60 * 60 * 24 * 30}
		}
		if not ok then
			logger.errorf("[memory] close uid:%s failed: %s", mem.uid, err)
		end
		if now > mem.update_time then -- 超过10分钟，已经不需要保留上下文了
			mem.compressed = {}
		else	-- 保留最后1条对话
			mem.compressed = {compressed[#compressed]}
		end
	end
	mem.process_version = modify_version
	core.timeout(1000, background_thinking)
end

function M.start()
	create_index()
	core.timeout(1000, background_thinking)
end

---@param uid number
---@return memory
function M.new(uid)
	local m = memory_cache[uid]
	m.update_time = time.nowsec()
	opening_memory[m] = true
	return m
end

---@param self memory
---@param tbl table{role: string, content: string}
---@param msg string
function M:retrieve(tbl, msg)
	-- 1. 长期记忆
	local txt, err = retrieval(self.uid, msg)
	if txt and #txt > 0 then
		tbl[#tbl + 1] = {
			role = "system",
			content = txt,
		}
	else
		logger.errorf("[memory] retrieval uid:%s failed: %s", self.uid, err)
	end
	-- 2. 用户画像信息
	local profile = self.profile
	tbl[#tbl + 1] = {
		role = "system",
		content = "用户画像信息：" .. profile,
	}
	-- 4. 添加近期上下文（如果有）
	local compressed = self.compressed
	if #compressed > 0 then
		tbl[#tbl + 1] = {
			role = "system",
			content = "近期上下文：" .. concat(compressed, "\n\n"),
		}
	end
	-- 5. 添加工作记忆
	local working = self.working
	for i = 1, #working do
		tbl[#tbl + 1] = working[i]
	end
	-- 6. 添加当前问题
	tbl[#tbl + 1] = {
		role = "user",
		content = msg,
	}
end

function M:add(q, a)
	self.modify_version = self.modify_version + 1
	local working = self.working
	working[#working + 1] = {
		role = "user",
		content = q,
	}
	working[#working + 1] = {
		role = "assistant",
		content = a,
	}
	self.update_time = time.nowsec()
	db:call("JSON.SET", format(dbk_user, self.uid), "$", json.encode(self))
end

function M:close()
	self.update_time = time.nowsec()
	closing_memory[self] = true
end

return M