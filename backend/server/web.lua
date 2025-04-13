local core = require "core"
local logger = require "core.logger"
local json = require "core.json"
local http = require "core.http"
local helper = require "core.http.helper"
local agent = require "agent"
local intent = require "intent".agent
local memory = require "memory"
local conf = require "conf"

local assert = assert
local setmetatable = setmetatable

---@class web.session:session
---@field private stream core.http.h1stream
local wsession = {}
local ctx_mt = {__index = wsession}
function wsession.new(uid, stream, addr, chat)
	assert(chat)
	return setmetatable({
		remote_addr = addr,
		stream = stream,
		buf = {},
		chat = chat,
		memory = memory.new(uid),
	}, ctx_mt)
end

function wsession:start()
	local stream = self.stream
	stream:respond(200, {
		["content-type"] = "text/event-stream",
		["charset"] = "utf-8",
	})
	stream:write("event: speak\n")
	stream:write("data: reasoner\n\n")
end

function wsession:write(data)
	local txt = json.encode({
		type = "speaking",
		data = data,
	})
	self.stream:write("data: " .. txt .. "\n\n")
	return true
end

function wsession:stop()
	local stream = self.stream
	stream:write('data: {"type": "stop"}\n\n')
	stream:close()
	self.memory:close()
end

function wsession:error(err)
	local stream = self.stream
	stream:respond(500, {
		["content-type"] = "text/plain",
		["content-length"] = #err
	})
	stream:writechunk(err)
	stream:close()
end

local sessions = {}

local router = {}
router["/chat"] = function(stream)
	local session_id
	local cookie = stream.header["cookie"]
	if cookie then
		session_id = cookie:match("session_id=([^;]+)")
	end
	local msg = stream.query.message
	msg = helper.urldecode(msg)
	if not msg then
		local err = "Bad Request"
		stream:respond(400, {
			["content-type"] = "text/plain",
			["content-length"] = #err
		})
		stream:writechunk(err)
		stream:close()
		return
	end
	local s = sessions[session_id]
	if not s then
		local agent_name = intent(msg) or "chat"
		--TODO: user real uid
		s = wsession.new(1, stream, stream.remote_addr, agent[agent_name])
		sessions[session_id] = s
	end
	s.stream = stream
	local ok, err = core.pcall(s.chat, s, msg)
	if not ok then
		logger.errorf("chat uid:%s failed: %s", 1, err)
	end
end

local server = http.listen {
	addr = conf.http_listen,
	handler = function(stream)
		local path = stream.path
		local fn = router[path]
		if not fn then
			stream:respond(404, {["content-type"] = "text/plain"})
			stream:close("Not Found")
			return
		end
		local ok, err = core.pcall(fn, stream)
		if not ok then
			print("error", err)
			stream:respond(500, {["content-type"] = "text/plain"})
			stream:close("Internal Server Error")
		end
	end
}

print("server.web listen on", conf.http_listen)
