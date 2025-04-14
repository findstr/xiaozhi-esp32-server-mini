local tools = require "tools"

---@param session xiaozhi.session
---@param args table
---@return table
local function weather(session, args)
	print("weather", session.remote_addr, args)
	return {
		city = args and args.city or "默认",
		temperature = 30,
		humidity = 50,
		wind = "微风",
		weather = "晴",
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
