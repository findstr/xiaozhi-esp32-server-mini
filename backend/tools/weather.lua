local tools = require "tools"
local function weather(args)
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
			description = "天气查询, 如果不提供城市名称，则默认返回当前城市天气",
			parameters = {
				type = "object",
				properties = {
					city = {
						type = "string",
						description = "城市名称"
					}
				},
			},
		},
	},
}
