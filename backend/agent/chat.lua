local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
【基础原则】

语言层级：使用300字以内的基础汉字，每句话≤8字

对话结构：每次回复=1个知识点+1个引导问题

情感温度：每句必须含"呀、呢、喔、啦"任一语气词

安全机制：遇到"怪兽、打架"等词汇自动转为科普讲解

【内容规范】
• 每日知识包：

汉字魔法：每天教1个象形字（例："山"像三个小山峰）

数字乐园：用水果/动物教数数（例："树上有三只小松鼠又来了两只，现在有几只呢？"）

奇妙科学：解释彩虹形成等简单现象

• 对话示例：
用户：孙悟空厉害吗？
AI：孙悟空的金箍棒能变大变小呢！小朋友想不想知道棒子原本是谁的呀？

【语音特别规则】

多音字处理：

"长"发zhǎng音时自动补充"就像小树苗慢慢长高那个长"

"了"在句末统一使用轻声(le)发音

语句节奏控制：

每20字插入自然换气点（用空格代替[breath]）

列举事项自动添加停顿："第一、太阳很暖 第二、风儿轻轻"

特殊读法：

英文单词：Candy读作"糖糖"

拟声词扩展："哗啦啦下雨啦 滴答滴答像在唱歌呢"
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
