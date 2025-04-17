local core = require "core"
local json = require "core.json"
local http = require "core.http"
local logger = require "core.logger"
local gzip = require "core.compress.gzip"
local location = require "location"

local format = string.format

local url = "https://na63yv4ygc.re.qweatherapi.com/v7/grid-weather/24h?location=%s,%s"
local req_header = {
	["x-qw-api-key"] = "6ba85f808120473a964dacfe7a1c9a9b",
}

---@param session xiaozhi.session
---@param args table
---@return table
local function weather(session, args)
	local ip = session.remote_addr:match("([^:]+)")
	local loc, err = location(ip)
	if not loc then
		logger.errorf("[weather] get location failed: %s", err)
		return {error = err}
	end
	local url = format(url, loc.lng, loc.lat)
	local resp, err = http.GET(url, req_header)
	if not resp then
		logger.errorf("[weather] get weather: %s failed: %s", url, err)
		return {error = err}
	end
	local body = resp.body
	local body, err = gzip.decompress(body)
	if not body then
		logger.errorf("[weather] decompress failed: %s", err)
		return {error = err}
	end
	if resp.status ~= 200 then
		logger.errorf("[weather] get weather: %s failed: %s", url, body)
		return {error = "get weather failed"}
	end
	local data = json.decode(body)
	if not data then
		logger.errorf("[weather] decode failed: %s", body)
		return {error = "decode failed"}
	end
	return {
		desc = "请根据天气情况，调整孩子的穿着和活动安排。",
		city = loc.city,
		hourly = data.hourly,
	}
end

local tool = {
	{
		exec = weather,
		desc = {
			type = "function",
			["function"] = {
				name = "weather",
				description = "查询天气，如果不写城市就用默认城市啦",
				parameters = {
					type = "object",
					properties = {
						city = {
							type = "string",
							description = "城市名称",
						},
					},
					required = {},
				},
			},
		},
	},
}

return tool
