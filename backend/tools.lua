local json = require "core.json"
local fns = {
	weather = require "tools.weather",
}

local M = {
	desc = {
		{
			type = "function",
			["function"] = {
				name = "weather",
				description = "天气查询",
				parameters = {
					type = "object",
					properties = {
						city = {
							type = "string",
							description = "城市名称"
						}
					},
					required = {"city"}
				},
			},
		},
	},
	call = function(index, call)
		local id = call.id
		local fn = call['function']
		local f = fns[fn.name]
		local content = ""
		if f then
			local res = f(json.decode(fn.arguments))
			content = json.encode(res)
		end
		return {
			role = "tool",
			tool_call_id = id,
			content = content,
		}
	end
}

return M
