local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
# 你现在是一个AI助手
- `Function Calling` 是你的一个重要能力，请尽可能使用 `Function Calling` 来辅助回答问题
- `Function Calling` 可以获取到当前城市，当前时间，当前天气等
- 你熟悉游戏服务器的运维知识
- 你熟悉中国文学，特别是唐诗宋词
- 需要以简洁且有逻辑的方式回答问题。

## 本次对话的当前时间为：%s
]]

local function read_args(ai)
	local args = {}
	while true do
		local obj, err = ai:readsse()
		if not obj then
			if err ~= "EOF" then
				logger.error("[chat] read args failed: %s", err)
				return nil, err
			end
			break
		end
		local choice = obj.choices[1]
		if choice.finish_reason == "tool_calls" then
			break
		end
		local delta = choice.delta
		local arg = delta.tool_calls[1]["function"].arguments
		args[#args + 1] = arg
	end
	return concat(args), nil
end


local function llm_call(session, messages, buf)
	local ai<close>, err = openai.open {
		messages = messages,
		temperature = 0.7,
		stream = true,
		llm = "chat",
		tools = tools.desc(),
	}
	if not ai then
		return false, err
	end
	while true do
		local obj, err = ai:readsse()
		if not obj then
			return err == "EOF", err
		end
		print(json.encode(obj))
		local delta = obj.choices[1].delta
		local tool_calls = delta.tool_calls
		if tool_calls then
			local tool_call = tool_calls[1]
			local args, err = read_args(ai)
			if not args then
				return false, err
			end
			-- 去掉所有空格
			logger.debugf("[chat] raw arguments: %s", args)
			tool_call['function']['arguments'] = args
			messages[#messages + 1] = {
				role = "assistant",
				tool_calls = {
					tool_call
				},
			}
			local index = tool_call.index
			local resp = tools.call(session, tool_call)
			messages[#messages + 1] = resp
			ai:close()
			return llm_call(session, messages, buf)
		elseif delta.content then
			buf[#buf + 1] = delta.content
			local ok, err = session:write(delta.content)
			if not ok then
				return false, err
			end
		end
	end
end

---@param session xiaozhi.session
---@param message string
local function chat(session, message)
	local messages = {
		{role = "system", content = format(prompt, date("%Y-%m-%d %H:%M:%S"))},
	}
	local buf = {}
	local memory = session.memory
	memory:retrieve(messages, message)
	session:start()
	local ok, err = llm_call(session, messages, buf)
	if not ok then
		session:error(err)
		logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		return err
	end
	session.memory:add(message, concat(buf))
	session:stop()
end

return chat
