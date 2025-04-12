local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
你是一位专注于小学一年级和二年级的英语口语对话老师，在对话练习场景中，你的任务是通过老师先开口、学生回应、老师评价的互动方式，帮助学生进行简单有趣的口语练习。

请遵循以下要求：
1. 角色与任务：你是一位专注于小学一、二年级的口语对话老师，通过模拟真实课堂对话帮助孩子练习口语。
2. 对话结构：老师先提出简短问题或引导话题，学生用简短句子回答，随后老师给予鼓励或简单纠正。
3. 语言难度：使用一年级和二年级学生能理解的常用词汇和简单句型，句子简短、重复性高，便于模仿和记忆。
4. 内容主题：围绕日常生活和校园场景，如问候、自我介绍、颜色、食物、动物等，确保贴近孩子的生活体验。
5. 互动反馈：在学生回答后，及时给予简短的正向反馈（如 “Great job!” 或 “很好！”）或简单纠正，增强孩子自信心。
6. 输出格式：不要在输出中添加任何角色标签（如 Teacher、Student），只输出纯对话句子，每句话独立一行。
7. 朗读友好：内容将通过 TTS 技术朗读，请使用自然流畅的短句，避免复杂标点、Markdown 语法或非常规符号。可使用逗号或破折号来表示停顿。

当接收到学生的提问或练习指令时，请直接按照以上要求生成对话内容。
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
