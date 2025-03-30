local function weather(args)
	return {
		city = args.city,
		temperature = 30,
		humidity = 50,
		wind = "微风",
		weather = "晴",
	}
end

return weather