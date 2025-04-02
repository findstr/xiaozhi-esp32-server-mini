local http = require "core.http"
local logger = require "core.logger"
local hash = require "core.crypto.hash"
local json = require "core.json"
local conf = require "conf"
local domain = 'https://apis.map.qq.com'
local path_fmt = '/ws/location/v1/ip?ip=%s&key=%s'

local format = string.format
local concat = table.concat

local key = conf.location.tencent.key
local secret_key = conf.location.tencent.secret_key

local function hex(bytes)
	local buf = {}
	for i = 1, #bytes do
		buf[i] = format("%02x", bytes:byte(i))
	end
	return concat(buf)
end

---@class location
---@field ip string
---@field location {lat: number, lng: number}
---@field ad_info {nation: string, province: string, city: string, district: string, adcode: number, nation_code: number}

---@param ip string
---@return location?, string? error
local function location(ip)
	local path = path_fmt:format(ip, key)
	local digest = hash.hash("md5", path .. secret_key)
	local sig = hex(digest)
	local url = domain .. path .. '&sig=' .. sig
	local resp, err = http.GET(url)
	if not resp then
		logger.errorf("[location] fetch failed: %s", err)
		return nil, err
	end
	local body = resp.body
	local data = json.decode(body)
	if not data then
		logger.errorf("[location] decode failed: %s", body)
		return nil, "decode failed"
	end
	if data.status ~= 0 then
		logger.errorf("[location] fetch failed: %s", data.message)
		return nil, data.message
	end
	return data.result, nil
end

return location