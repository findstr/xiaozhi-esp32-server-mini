local core = require "core"
local time = require "core.time"
local logger = require "core.logger"
local conf = require "conf"
local tts = require ("tts." .. conf.tts.use)

local setmetatable = setmetatable
local len = utf8.len
local min_char<const> = 5
local max_char<const> = 10

---@class tts
---@field buf string
---@field min_char number
---@field last_tts_time number
local M = {}
local mt = {__index = M}

---@return tts
function M.new()
	return setmetatable({
		buf = "",
		min_char = min_char,
		last_tts_time = 0,
	}, mt)
end

---@param txt string
---@param pcm_cb fun(pcm: string)
---@return boolean
function M:txt_to_pcm(txt, pcm_cb)
	self:rate_limit()
	local ok = tts(txt, pcm_cb)
	self.last_tts_time = time.now()
	return ok
end

function M:rate_limit()
	local nowms = time.now()
	if nowms < self.last_tts_time + 500 then
		core.sleep(self.last_tts_time + 500 - nowms)
	end
end

---@param txt_cb fun(txt: string)
---@param pcm_cb fun(pcm: string)
---@return boolean
function M:flush(txt_cb, pcm_cb)
	self.min_char = min_char
	local buf = self.buf
	local x = string.gsub(buf, "%s+", "")
	if #x == 0 then
		return true
	end
	txt_cb(buf)
	local ok = self:txt_to_pcm(buf, pcm_cb)
	self.buf = ""
	return ok
end

local sep = {}
for _, c in utf8.codes("。！？，,!?.\n") do
	sep[c] = true
end

---@param txt string
---@param txt_cb fun(txt: string)
---@param pcm_cb fun(pcm: string)
---@return boolean
function M:speak(txt, txt_cb, pcm_cb)
	local buf = self.buf .. txt
	self.buf = buf
	if len(buf) < self.min_char then
		return true
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
		return true
	end
	local try_to_use = buf:sub(1, x-1)
	if len(try_to_use) < self.min_char then
		return true
	end
	self.min_char = max_char
	self.buf = buf:sub(x)
	txt_cb(try_to_use)
	return self:txt_to_pcm(try_to_use, pcm_cb)
end

return M