local logger = require "silly.logger"
local dns = require "silly.net.dns"
local xiaozhi = require "server.xiaozhi"
local conf = require "conf"
local concat = table.concat
local silly = require "silly"
local task = require "silly.task"
local logger = require "silly.logger"
local json = require "silly.encoding.json"
local http = require "silly.net.http"
local helper = require "silly.net.http.helper"
local channel = require "silly.sync.channel"
local waitgroup = require "silly.sync.waitgroup"
local conf = require "conf"
local setmetatable = setmetatable

logger.debugf("[main] start")

--- load config
do
	local function merge_conf(base, override)
		for k, src in pairs(base) do
			local dst = override[k]
			if dst then
				if type(src) == "table" and type(dst) == "table" then
					merge_conf(src, dst)
				else
					base[k] = dst
				end
			end
		end
	end
	local ok, override_conf = pcall(require, "myconf")
	if ok then
		logger.infof("[main] load myconf.lua")
		merge_conf(conf, override_conf)
	end
	dns.server("223.5.5.5:53")
	--local ip = dns.lookup(conf.vector_db.redis.addr, dns.A)
	--logger.infof("[main] redis ip: %s", ip)
	--conf.vector_db.redis.addr = ip
end
logger.setlevel(logger.DEBUG)


---@class web.session:session
---@field stream silly.net.http.h1.stream
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
		stream:closewrite(err)
		return
	end
	local wg = waitgroup.new()
	local s = sessions[session_id]
	if not s then
		--TODO: user real uid
		s = wsession.new(1, stream.remoteaddr())
		sessions[session_id] = s
		wg:fork(function()
			local ok, err = silly.pcall(agent, s)
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
		url = xiaozhi_websocket,
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
	addr = ":80",
	handler = function(stream)
		local path = stream.path
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

--[[
local tts = require "tts.edge"
local buf = {}

tts("床前明月光，疑是地上霜。举头望明月，低头思故乡。", function(pcm)
	buf[#buf + 1] = pcm
end)

local file, err = io.open("output.pcm", "wb")
if not file then
	logger.errorf("[main] open file error: %s", err)
	return
end
local pcm = table.concat(buf, "")
print("PCM:", #pcm)
file:write(pcm)
file:close()
]]

--[[
local core = require "core"
local riddle = require "agent.riddle".exec
local channel = require "silly.sync.channel"
---@type session
local session = {
	uid = "1234567890",
	remoteaddr = "127.0.0.1:12345",
	ch_llm_input = channel.new(),
	ch_llm_output = channel.new(),
}
silly.fork(function()
	riddle(session)
end)

local function read_chunk(ch_in)
	local buf = {}
	while true do
		local msg = ch_in:pop()
		if not msg or msg == "" then
			break
		end
		buf[#buf + 1] = msg
	end
	return concat(buf)
end
]]

--[[
session.ch_llm_input:push("我们来玩脑筋急转弯吧。我来出题")
local msg = read_chunk(session.ch_llm_output)
print("AI:", msg)

print("--------------------------------")
session.ch_llm_input:push("什么东西越洗越脏？")
local msg2 = read_chunk(session.ch_llm_output)
print("AI:", msg2)
session.ch_llm_input:push("对了")
local msg3 = read_chunk(session.ch_llm_output)
print("AI:", msg3)

print("--------------------------------")
session.ch_llm_input:push("为什么飞机撞不到星星？")
local msg4 = read_chunk(session.ch_llm_output)
print("AI:", msg4)
session.ch_llm_input:push("错了, 因为星星会闪")
local msg6 = read_chunk(session.ch_llm_output)
print("AI:", msg6)

session.ch_llm_input:push("我们来玩脑筋急转弯吧。你来出题。")
print("--------------------------------")
local msg = read_chunk(session.ch_llm_output)
print("AI:", msg)
session.ch_llm_input:push("我猜是因为打架")
local msg2 = read_chunk(session.ch_llm_output)
print("AI:", msg2)
print("-------------------------------")
local msg3 = read_chunk(session.ch_llm_output)
print("AI:", msg3)
session.ch_llm_input:push("是不是因为我不饿")
local msg4 = read_chunk(session.ch_llm_output)
print("AI:", msg4)
print("--------------------------------")

]]