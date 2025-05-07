local core = require "core"
local time = require "core.time"
local logger = require "core.logger"
local json = require "core.json"
local http = require "core.http"
local helper = require "core.http.helper"
local channel = require "core.sync.channel"
local waitgroup = require "core.sync.waitgroup"
local intent = require "intent".agent
local conf = require "conf"

local xiaozhi_websocket = conf.xiaozhi_websocket

local setmetatable = setmetatable

---@class web.session:session
---@field stream core.http.h1stream
local wsession = {}
local ctx_mt = {__index = wsession}

---@param uid number
---@param addr string
---@return web.session
function wsession.new(uid, addr)
	return setmetatable({
		uid = uid,
		remoteaddr = addr,
		ch_llm_input = channel.new(),
		ch_llm_output = channel.new(),
	}, ctx_mt)
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
	local wg = waitgroup.new()
	local s = sessions[session_id]
	if not s then
		local agent = intent(msg)
		--TODO: user real uid
		s = wsession.new(1, stream.remoteaddr)
		sessions[session_id] = s
		wg:fork(function()
			local ok, err = core.pcall(agent, s)
			if not ok then
				logger.errorf("server.web agent error: %s", err)
			end
			s.ch_llm_output:close()
		end)
	end
	s.ch_llm_input:push(msg)
	wg:fork(function()
		stream:respond(200, {
			["content-type"] = "text/event-stream",
			["charset"] = "utf-8",
		})
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

router["/ota"] = function(stream)
	logger.debug("ota request")
	local url = "https://api.tenclass.net/xiaozhi/ota/"
	local header = stream.header
	local body = stream:readall()
	local resp, err = http.POST(url, header, body)
	if not resp then
		stream:respond(500, {["content-type"] = "text/plain"})
		stream:close(err)
		return
	end
	local remote_body = resp.body
	local status = resp.status
	if status ~= 200 then
		stream:respond(status, {["content-type"] = "text/plain"})
		stream:close(remote_body)
		return
	end
	local obj = json.decode(resp.body)
	obj.mqtt = nil
	obj.websocket = {
		url = xiaozhi_websocket,
		token = "test-token",
	}
	local body = json.encode(obj)
	local headers = {
		["content-type"] = "application/json",
		["content-length"] = #body,
	}
	stream:respond(200, headers)
	stream:close(body)
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
			logger.errorf("server.web error: %s", err)
			stream:respond(500, {["content-type"] = "text/plain"})
			stream:close("Internal Server Error")
		end
	end
}

logger.infof("server.web listen on %s", conf.http_listen)
