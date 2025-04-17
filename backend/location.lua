local http = require "core.http"
local logger = require "core.logger"
local hash = require "core.crypto.hash"
local json = require "core.json"
local conf = require "conf"
local domain = 'https://apis.map.qq.com'
local lan_fmt = '/ws/location/v1/ip?key=%s'
local wan_fmt = '/ws/location/v1/ip?ip=%s&key=%s'

local tonumber = tonumber
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

-- 将IP地址字符串转为数值
local function ip_to_number(ip)
	local o1, o2, o3, o4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return tonumber(o1) * 256^3 + tonumber(o2) * 256^2 + tonumber(o3) * 256 + tonumber(o4)
end

-- 判断是否是局域网IP
local function is_private_ip(ip)
	if ip == "127.0.0.1" then
		return true
	end
	local ip_num = ip_to_number(ip)

	local ip10_start = ip_to_number("10.0.0.0")
	local ip10_end   = ip_to_number("10.255.255.255")

	local ip172_start = ip_to_number("172.16.0.0")
	local ip172_end   = ip_to_number("172.31.255.255")

	local ip192_start = ip_to_number("192.168.0.0")
	local ip192_end   = ip_to_number("192.168.255.255")

	return (ip_num >= ip10_start and ip_num <= ip10_end)
		or (ip_num >= ip172_start and ip_num <= ip172_end)
		or (ip_num >= ip192_start and ip_num <= ip192_end)
end

print(is_private_ip("10.0.0.1"))

---@class location
---@field ip string
---@field location {lat: number, lng: number}
---@field ad_info {nation: string, province: string, city: string, district: string, adcode: number, nation_code: number}

---@param ip string
---@return {lat: number, lng: number, city: string}?, string? error
local function location(ip)
	if conf.location.use == "custom" then
		return conf.location.custom, nil
	end
	local path
	if is_private_ip(ip) then
		path = lan_fmt:format(key)
	else
		path = wan_fmt:format(ip, key)
	end
	logger.debugf("[location] path: %s", path)
	local digest = hash.hash("md5", path .. secret_key)
	local sig = hex(digest)
	local url = domain .. path .. '&sig=' .. sig
	local resp, err = http.GET(url)
	if not resp then
		logger.errorf("[location] fetch failed: %s", err)
		return nil, err
	end
	local body = resp.body
	logger.debugf("[location] %s", body)
	local data = json.decode(body)
	if not data then
		logger.errorf("[location] decode failed: %s", body)
		return nil, "decode failed"
	end
	if data.status ~= 0 then
		logger.errorf("[location] fetch failed: %s", data.message)
		return nil, data.message
	end
	local result = data.result
	local location = {
		lat = result.location.lat,
		lng = result.location.lng,
		city = result.ad_info.city,
	}
	return location, nil
end

return location