local logger = require "silly.logger"
local dns = require "silly.net.dns"
local xiaozhi = require "server.xiaozhi"
local conf = require "conf"
local silly = require "silly"
local json = require "silly.encoding.json"
local http = require "silly.net.http"
local helper = require "silly.net.http.helper"
local time = require "silly.time"
local channel = require "silly.sync.channel"
local waitgroup = require "silly.sync.waitgroup"
local memory = require "memory"
local agent_chat = require("agent.chat").exec
local setmetatable = setmetatable
local config_file = "backend/data/config.json"
local static_root = "backend/static"

local function normalize_profiles()
	if conf.asr and conf.asr.profiles then
		local name = conf.asr.use_name or "默认"
		for _, p in ipairs(conf.asr.profiles) do
			if p.name == name then
				conf.asr.use = p.use
				conf.asr.tencent = p.tencent or conf.asr.tencent
				break
			end
		end
	end
	if conf.tts and conf.tts.profiles then
		local name = conf.tts.use_name or "默认"
		for _, p in ipairs(conf.tts.profiles) do
			if p.name == name then
				conf.tts.use = p.use
				conf.tts.azure = p.azure or conf.tts.azure
				break
			end
		end
	end
	if conf.llm and conf.llm.profiles then
		local name = conf.llm.use_name or "默认"
		for _, p in ipairs(conf.llm.profiles) do
			if p.name == name then
				conf.llm.chat = p.chat or conf.llm.chat
				conf.llm.think = p.think or conf.llm.think
				break
			end
		end
	end
end

local function reload_modules()
	package.loaded["asr"] = nil
	package.loaded["asr.tencent"] = nil
	package.loaded["tts"] = nil
	package.loaded["tts.edge"] = nil
	package.loaded["tts.azure"] = nil
end

local function merge_conf(base, override)
	for k, src in pairs(base) do
		local dst = override[k]
		if dst ~= nil then
			if type(src) == "table" and type(dst) == "table" then
				merge_conf(src, dst)
			else
				base[k] = dst
			end
		end
	end
	for k, dst in pairs(override) do
		if base[k] == nil then
			base[k] = dst
		end
	end
end

logger.debugf("[main] start")

--- load config
do
	local ok, override_conf = pcall(require, "myconf")
	if ok then
		logger.infof("[main] load myconf.lua")
		merge_conf(conf, override_conf)
	end
	local f = io.open(config_file, "r")
	if f then
		local content = f:read("a")
		f:close()
		if content and #content > 0 then
			local ok2, obj = pcall(json.decode, content)
			if ok2 and obj then
				merge_conf(conf, obj)
			else
				logger.errorf("[main] load config json failed")
			end
		end
	end
	normalize_profiles()
	dns.server("223.5.5.5:53")
end
logger.setlevel(logger.DEBUG)
memory.init()

local function content_type(path)
	local ext = path:match("%.([%w]+)$")
	if ext == "html" then
		return "text/html; charset=utf-8"
	elseif ext == "css" then
		return "text/css; charset=utf-8"
	elseif ext == "js" then
		return "application/javascript; charset=utf-8"
	elseif ext == "json" then
		return "application/json; charset=utf-8"
	elseif ext == "png" then
		return "image/png"
	elseif ext == "svg" then
		return "image/svg+xml"
	end
	return "application/octet-stream"
end

local function send_file(stream, path)
	local f = io.open(path, "rb")
	if not f then
		stream:respond(404, {["content-type"] = "text/plain"})
		stream:closewrite("Not Found")
		return
	end
	local data = f:read("a")
	f:close()
	stream:respond(200, {
		["content-type"] = content_type(path),
		["content-length"] = #data,
	})
	stream:closewrite(data)
end


---@class web.session:session
---@field stream silly.net.http.h1.stream
local wsession = {}
local ctx_mt = {__index = wsession}

---@param uid number
---@param addr string
---@param session_id string
---@return web.session
function wsession.new(uid, addr, session_id)
	return setmetatable({
		uid = uid,
		remoteaddr = addr,
		session_id = session_id,
		ch_llm_input = channel.new(),
		ch_llm_output = channel.new(),
	}, ctx_mt)
end

local sessions = {}

local router = {}
router["/chat"] = function(stream)
	local session_id
	local new_cookie = false
	local cookie = stream.header["cookie"]
	if cookie then
		session_id = cookie:match("session_id=([^;]+)")
	end
	if not session_id or #session_id == 0 then
		session_id = tostring(time.now()) .. "-" .. tostring(math.random(100000, 999999))
		new_cookie = true
	end
	local msg = stream.query.message
	msg = helper.urldecode(msg)
	if not msg then
		local err = "Bad Request"
		stream:respond(400, {
			["content-type"] = "text/plain",
			["content-length"] = #err
		})
		stream:closewrite(err)
		return
	end
	local wg = waitgroup.new()
	local s = sessions[session_id]
	if not s then
		--TODO: user real uid
		s = wsession.new(1, stream.remoteaddr(), session_id)
		sessions[session_id] = s
		wg:fork(function()
			local ok, err = silly.pcall(agent_chat, s)
			if not ok then
				logger.errorf("server.web agent error: %s", err)
			end
			s.ch_llm_output:close()
		end)
	end
	s.ch_llm_input:push(msg)
	wg:fork(function()
		local headers = {
			["content-type"] = "text/event-stream",
			["charset"] = "utf-8",
		}
		if new_cookie then
			headers["set-cookie"] = "session_id=" .. session_id .. "; Path=/"
		end
		stream:respond(200, headers)
		stream:write("event: speak\n")
		stream:write("data: reasoner\n\n")
		local ch_llm_output = s.ch_llm_output
		while true do
			local data = ch_llm_output:pop()
			if not data then
				break
			end
			if #data == 0 then
				stream:write('data: {"type": "stop"}\n\n')
				break
			end
			local txt = json.encode({
				type = "speaking",
				data = data,
			})
			stream:write("data: " .. txt .. "\n\n")
		end
		stream:close()
	end)
	wg:wait()
end

router["/"] = function(stream)
	send_file(stream, static_root .. "/index.html")
end

router["/manager"] = function(stream)
	send_file(stream, static_root .. "/manager.html")
end

router["/chat-ui"] = function(stream)
	send_file(stream, static_root .. "/chat.html")
end

router["/manager/config"] = function(stream)
	if stream.method == "POST" then
		local body = stream:readall()
		local ok, obj = pcall(json.decode, body or "")
		if not ok or not obj then
			stream:respond(400, {["content-type"] = "text/plain"})
			stream:closewrite("Bad Request")
			return
		end
		local encoded = json.encode(obj)
		local f = io.open(config_file, "w")
		if not f then
			stream:respond(500, {["content-type"] = "text/plain"})
			stream:closewrite("Write Failed")
			return
		end
		f:write(encoded)
		f:close()
		merge_conf(conf, obj)
		normalize_profiles()
		memory.reload_conf()
		if memory.reload_logs then
			memory.reload_logs()
		end
		reload_modules()
		stream:respond(200, {["content-type"] = "application/json"})
		stream:closewrite("{\"ok\":true}")
		return
	end
	local body = json.encode(conf)
	stream:respond(200, {
		["content-type"] = "application/json; charset=utf-8",
		["content-length"] = #body,
	})
	stream:closewrite(body)
end

router["/manager/summary"] = function(stream)
	if stream.method == "POST" then
		local body = stream:readall() or ""
		memory.set_summary(body)
		stream:respond(200, {["content-type"] = "application/json"})
		stream:closewrite("{\"ok\":true}")
		return
	end
	local body = memory.get_summary()
	stream:respond(200, {
		["content-type"] = "text/plain; charset=utf-8",
		["content-length"] = #body,
	})
	stream:closewrite(body)
end

router["/manager/log/download"] = function(stream)
	local path = (conf.history and conf.history.log_file) or "data/chat.jsonl"
	send_file(stream, path)
end

router["/manager/log/upload"] = function(stream)
	local body = stream:readall() or ""
	local path = (conf.history and conf.history.log_file) or "data/chat.jsonl"
	local f = io.open(path, "w")
	if not f then
		stream:respond(500, {["content-type"] = "text/plain"})
		stream:closewrite("Write Failed")
		return
	end
	f:write(body)
	f:close()
	if memory.reload_logs then
		memory.reload_logs()
	end
	stream:respond(200, {["content-type"] = "application/json"})
	stream:closewrite("{\"ok\":true}")
end

router["/manager/sessions"] = function(stream)
	local list = memory.list_sessions()
	local body = json.encode(list)
	stream:respond(200, {
		["content-type"] = "application/json; charset=utf-8",
		["content-length"] = #body,
	})
	stream:closewrite(body)
end

router["/manager/session"] = function(stream)
	local sid = stream.query.session_id
	if not sid or #sid == 0 then
		stream:respond(400, {["content-type"] = "text/plain"})
		stream:closewrite("Bad Request")
		return
	end
	local limit = tonumber(stream.query.limit or "") or 100
	local max_tokens = tonumber(stream.query.max_tokens or "") or (conf.history and conf.history.context_max_tokens) or 2000
	local history = memory.get_session_history(sid, limit, max_tokens)
	local body = json.encode(history)
	stream:respond(200, {
		["content-type"] = "application/json; charset=utf-8",
		["content-length"] = #body,
	})
	stream:closewrite(body)
end

router["/xiaozhi/ota/"] = function(stream)
	local url = "https://api.tenclass.net/xiaozhi/ota/"
	local header = stream.header
	local body = stream:readall()
	logger.debug("ota request header:%s body:%d", json.encode(header), body)
	local resp, err = http.post(url, header, body)
	if not resp then
		stream:respond(500, {["content-type"] = "text/plain"})
		stream:closewrite(err)
		return
	end
	local remote_body = resp.body
	local status = resp.status
	if status ~= 200 then
		stream:respond(status, {["content-type"] = "text/plain"})
		stream:closewrite(remote_body)
		return
	end
	print("remote_body", remote_body)
	local obj = json.decode(resp.body)
	obj.mqtt = nil
	obj.websocket = {
		url = conf.xiaozhi_websocket,
		token = "test-token",
	}
	local body = json.encode(obj)
	local headers = {
		["content-type"] = "application/json",
		["content-length"] = #body,
	}
	stream:respond(200, headers)
	stream:closewrite(body)
end

router["/xiaozhi/v1/"] = xiaozhi

local server = http.listen {
	addr = conf.http_listen,
	handler = function(stream)
		local path = stream.path
		if path:sub(1, 8) == "/assets/" then
			send_file(stream, static_root .. path)
			return
		end
		local fn = router[path]
		if not fn then
			logger.infof("http path:%s not found", path)
			stream:respond(404, {["content-type"] = "text/plain"})
			stream:closewrite("Not Found")
			return
		end
		local ok, err = silly.pcall(fn, stream)
		if not ok then
			logger.errorf("server.web error: %s", err)
			stream:respond(500, {["content-type"] = "text/plain"})
			stream:closewrite("Internal Server Error")
		end
	end
}

logger.infof("server.web listen on %s", conf.http_listen)
