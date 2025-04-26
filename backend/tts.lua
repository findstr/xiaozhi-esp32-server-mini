local core = require "core"
local time = require "core.time"
local logger = require "core.logger"
local conf = require "conf"
local tts = require ("tts." .. conf.tts.use)

local setmetatable = setmetatable
local len = utf8.len
local min_char<const> = 8
local max_char<const> = 16

---@class tts
local M = {}
local mt = {__index = M}

function M.new()
	return setmetatable({
		buf = "",
		min_char = min_char,
		last_tts_time = 0,
	}, mt)
end

function M:txt_to_pcm(txt, is_last)
	self:rate_limit()
	local data, err = tts(txt)
	self.last_tts_time = time.now()
	if not data then
		logger.errorf("[tts] close failed to tts: %s", err)
		return nil, err
	end
	return data, err
end

function M:rate_limit()
	local nowms = time.now()
	if nowms < self.last_tts_time + 500 then
		core.sleep(self.last_tts_time + 500 - nowms)
	end
end

function M:flush()
	local buf = self.buf
	local pcm_data = self:txt_to_pcm(buf, true)
	self.buf = ""
	return pcm_data
end

function M:close()
	local stream = self.stream
	if stream then
		stream:close()
		stream = nil
	end
	logger.debug("[tts] close stream")
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
		return nil, "no end of sentence"
	end
	local try_to_use = buf:sub(1, x-1)
	if len(try_to_use) < self.min_char then
		return nil, nil
	end
	self.min_char = max_char
	self.buf = buf:sub(x)
	local pcm, err = self:txt_to_pcm(try_to_use, false)
	if not pcm then
		return nil, err
	end
	return pcm, try_to_use
end

return M