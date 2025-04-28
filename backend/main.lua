local logger = require "core.logger"
local dns = require "core.dns"
local conf = require "conf"

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
	dns.server("8.8.8.8:53")
	local ip = dns.lookup(conf.vector_db.redis.addr, dns.A)
	logger.infof("[main] redis ip: %s", ip)
	conf.vector_db.redis.addr = ip
end


local memory = require "memory"
memory.start()

require "server.web"
require "server.xiaozhi"

--[[
local voice = require "voice.mpg123"
local file, err = io.open("output.mp3", "rb")
if not file then
	logger.errorf("[main] open file error: %s", err)
	return
end
local mp3 = file:read("*a")
file:close()

local vad = voice.new()
local buffer = {}
for i = 1, #mp3, 64 do
	local e = i + 63
	if e > #mp3 then
		e = #mp3
	end
	local ctx = mp3:sub(i, e)
	local pcm = voice.mp3topcm(vad, ctx)
	if pcm then
		table.insert(buffer, pcm)
	end
end

voice.reset(vad)
buffer = {}
for i = 1, #mp3, 64 do
	local e = i + 63
	if e > #mp3 then
		e = #mp3
	end
	local ctx = mp3:sub(i, e)
	local pcm = voice.mp3topcm(vad, ctx)
	if pcm then
		table.insert(buffer, pcm)
	end
end


local file, err = io.open("output.pcm", "wb")
if not file then
	logger.errorf("[main] open file error: %s", err)
	return
end
local pcm = table.concat(buffer, "")
print(#pcm)
file:write(pcm)
file:close()


]]