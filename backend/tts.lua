local core = require "core"
local time = require "core.time"
local grpc = require "core.grpc"
local logger = require "core.logger"
local protoc = require "protoc"
local conf = require "conf"
local tts = require ("tts." .. conf.tts.use)

local setmetatable = setmetatable
local len = utf8.len
local min_char<const> = 5
local max_char<const> = 32

local p = protoc:new()


local f<close>, err = io.open("proto/opus.proto")
assert(f, err)
local data = f:read("a")
local ok = p:load(data, "opus.proto")
assert(ok)

local proto = p.loaded["opus.proto"]
local client, err = grpc.newclient {
	service = "Opus",
	endpoints = {conf.opus.grpc_addr},
	proto = proto,
	timeout = 5000,
}
assert(client, err)

local M = {}
local mt = {__index = M, __gc = function(t)
	local stream = t.stream
	if stream then
		stream:close()
		t.stream = nil
	end
end}

function M.new()
	local stream, err = client.WrapPCM()
	if not stream then
		logger.errorf("[tts] failed to wrap grpc: %s", err)
		return nil, err
	end
	return setmetatable({
		stream = stream,
		buf = "",
		min_char = min_char,
		last_tts_time = 0,
	}, mt)
end

function M:txt_to_opus(txt, is_last)
	self:rate_limit()
	local data, err = tts(txt)
	self.last_tts_time = time.now()
	if not data then
		logger.errorf("[tts] close failed to tts: %s", err)
		return nil
	end
	local stream = self.stream
	stream:write {
		is_last = is_last,
		pcm_data = data,
	}
	local opus_datas
	local res, err = stream:read()
	if not res then
		logger.errorf("[tts] failed to read from grpc: %s", err)
	else
		opus_datas = res.opus_datas
	end
	return opus_datas
end

function M:rate_limit()
	local nowms = time.now()
	if nowms < self.last_tts_time + 500 then
		core.sleep(self.last_tts_time + 500 - nowms)
	end
end

function M:close()
	local stream = self.stream
	if not stream then
		logger.error("[tts] close stream is nil")
		return nil
	end
	local buf = self.buf
	local opus_datas = self:txt_to_opus(buf, true)
	self.buf = ""
	stream:close()
	self.stream = nil
	return opus_datas, buf
end

local sep = {}
for _, c in utf8.codes("。！？，,!?.") do
	sep[c] = true
end

function M:speak(txt)
	local buf = self.buf .. txt
	self.buf = buf
	if len(buf) < self.min_char then
		return nil, nil
	end
	local x
	local hit = false
	for pb, c in utf8.codes(buf) do
		if hit then
			x = pb
			hit = false
		end
		if sep[c] then
			hit = true
		end
	end
	if hit then
		x = #buf + 1
	end
	if not x then
		return nil, nil
	end
	local try_to_use = buf:sub(1, x-1)
	if len(try_to_use) < self.min_char then
		return nil, nil
	end
	self.min_char = max_char
	self.buf = buf:sub(x)
	return self:txt_to_opus(try_to_use, false), try_to_use
end

return M