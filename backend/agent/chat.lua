local logger = require "core.logger"
local openai = require "openai"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
# 你现在是聊天机器人, 回答是简洁，有逻辑的。
- 只能使用中文标点符号。
- 当前提问时间是: %s]]

---@param session session
---@param message string
local function chat(session, message)
	local messages = {
		{role = "system", content = format(prompt, date("%Y-%m-%d %H:%M:%S"))},
	}
	local memory = session.memory
	memory:retrieve(messages, message)
	local ai<close>, err = openai.open {
		messages = messages,
		temperature = 0.9,
		stream = true,
		llm = "chat",
	}
	if not ai then
		session:error(err)
		logger.error("chat uid:%v openai failed: %v", session.uid, err)
		return err
	end
	local buf = {}
	session:start()
	local broken = false
	while true do
		local obj, err = ai:readsse()
		if not obj then
			if err ~= "EOF" then
				logger.error("chat uid:%v readsse failed: %v", session.uid, err)
			end
			break
		end
		local content = obj.choices[1].delta.content
		if content then
			buf[#buf + 1] = content
			local ok = session:write(content)
			if not ok then
				broken = true
				break
			end
		end
	end
	ai:close()
	if not broken then
		session.memory:add(message, concat(buf))
	end
	session:stop()
end

return chat
