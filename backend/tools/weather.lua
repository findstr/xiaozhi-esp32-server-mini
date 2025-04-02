local tools = require "tools"

---@param session xiaozhi.session
---@param args table
---@return table
local function weather(session, args)
	print("weather", session.remote_addr, args)
	return {
		city = args.city,
		temperature = 30,
		humidity = 50,
		wind = "微风",
		weather = "晴",
	}
end

tools.register {
	{
		type = "function",
		exec = weather,
		["function"] = {
			name = "weather",
			description = "天气查询, 支持不提供城市名称",
			parameters = {
				type = "object",
				properties = {
					city = {
						type = "string",
						description = "城市名称",
					}
				},
			},
		},
	},
}
