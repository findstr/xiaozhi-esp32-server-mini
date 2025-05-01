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
