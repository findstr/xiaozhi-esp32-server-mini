local logger = require "core.logger"
local dns = require "core.dns"
local conf = require "conf"
local concat = table.concat

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
	local ip = dns.lookup(conf.vector_db.redis.addr, dns.A)
	logger.infof("[main] redis ip: %s", ip)
	conf.vector_db.redis.addr = ip
end


local memory = require "memory"
memory.start()

require "server.web"
require "server.xiaozhi"

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
local channel = require "core.sync.channel"
---@type session
local session = {
	uid = "1234567890",
	remoteaddr = "127.0.0.1:12345",
	ch_llm_input = channel.new(),
	ch_llm_output = channel.new(),
}
core.fork(function()
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