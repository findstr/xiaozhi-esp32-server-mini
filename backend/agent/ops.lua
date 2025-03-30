local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local tools = require "tools"

local prompt = [[
你是一个游戏运维专家，用户会提出各种运维相关的问题，你需要拆解问题，并生成一个详细的分步执行计划，以便后续调用 API 来完成任务。

请遵循以下规则：

分析用户需求，根据函数列表，判断要将问题拆解为哪些步骤。
按照逻辑顺序拆解任务，列出每一步需要调用的函数和参数。
确保步骤完整，避免遗漏关键信息。
输出 JSON 格式:[{step_number（步骤编号）、description（步骤描述）、function_name（函数名）、parameters（函数参数）}]
]]

--[[
下面上一些基础知识:

- "xxx服"服务器的名字
- "redis" 是数据库
]]

---@param session session
---@param message string
local function ops(session, message)
	local messages = {
		{role = "system", content = prompt},
		{role = "system", content = json.encode(tools.desc)},
		{role = "user", content = message},
	}
	--local memory = session.memory
	--memory:retrieve(messages, message)

	local ai, err = openai.open {
		messages = messages,
		temperature = 0.9,
		stream = false,
		llm = "ops",
	}
	print("-------------1", ai)
	if not ai then
		session:error(err)
		logger.error("chat uid:%v openai failed: %v", session.uid, err)
		return err
	end
	local obj, err = ai:read()
	print("-------------2", obj)
	if not obj then
		session:error(err)
		logger.error("chat uid:%v openai failed: %v", session.uid, err)
		return err
	end
	ai:close()
	local plan_txt = obj.choices[1].message.content
	print("-------------4", plan_txt)
	local plans = json.decode(plan_txt)
	session:start()
	for i, plan in ipairs(plans) do
		print("-------------3", plan.description)
		messages[#messages + 1] = {
			role = "user", content = plan.description
		}
		for i = 1, 50 do
			local ai<close>, err = openai.open {
				messages = messages,
				temperature = 0.9,
				stream = false,
				llm = "ops",
				tools = tools.desc,
			}
			if not ai then
				session:error(err)
				logger.error("chat uid:%v openai failed: %v", session.uid, err)
				return err
			end
			local obj, err = ai:read()
			if not obj then
				if err ~= "EOF" then
					logger.error("chat uid:%v readsse failed: %v", session.uid, err)
				end
				break
			end
			print(json.encode(obj))
			local choice = obj.choices[1]
			local message = choice.message
			if message.tool_calls then
				messages[#messages + 1] = message
				local index = message.index
				for _, call in ipairs(message.tool_calls) do
					local resp = tools.call(index, call)
					messages[#messages + 1] = resp
				end
			elseif message.content and i == #plans then
				session:write(message.content)
				session:stop()
				return
			end
		end
	end
end

return ops
