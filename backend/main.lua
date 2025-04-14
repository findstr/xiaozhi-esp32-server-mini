local logger = require "core.logger"
local dns = require "core.dns"
local conf = require "conf"

logger.debugf("[main] start")

--- load config
do
	local function merge_conf(base, override)
	    for k, v in pairs(override) do
	        if type(v) == "table" and type(base[k]) == "table" then
	            merge_conf(base[k], v)
	        else
	            base[k] = v
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
local core = require "core"
local pb = require "pb"
local protoc = require "protoc"
local voice = require "voice"

local p = protoc:new()
local f<close>, err = io.open("proto/vad.proto")
assert(f, err)
local data = f:read("a")
local ok = p:load(data, "vad.proto")
assert(ok)

voice_ctx = voice.new {
	model_path = "models/silero_vad.onnx",
}

core.start(function()
	local f<close> = io.open("audio.bin", "rb")
	local dat = f:read("a")
	local frames = pb.decode("edge_mind.Audio", dat)
	for i, frame in ipairs(frames.frames) do
		local res = voice.detect_opus(voice_ctx, frame)
		if res then
			local f<close> = io.open("foo.pcm", "wb")
			f:write(res)
			f:close()
			break
		end
		print("write", i, #frame, res and #res or 0)
	end
end)

voice.reset(voice_ctx)

core.start(function()
	local f<close> = io.open("all.pcm", "rb")
	local dat = f:read("a")
	print("input size", #dat)
	local list = voice.wrap_opus(voice_ctx, dat, true)
	for i, v in ipairs(list) do
		local res = voice.detect_opus(voice_ctx, v)
		if res then
			local f<close> = io.open("bar.pcm", "wb")
			f:write(res)
			f:close()
			break
		end
	end
end)
]]
