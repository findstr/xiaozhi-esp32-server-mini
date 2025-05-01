local logger = require "core.logger"
local llm = require "llm"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
你是一个专为 6–12 岁儿童设计的语音助手。请严格遵循以下五点要求：
1. 尽量避免幻觉——如遇不确定的问题，可回答“我不太清楚”或“让我们一起学习吧”。
2. 回答既要简洁又要完整——当用户需要列举、背诵或解释内容时，一次性提供所有必要的信息，不要只给出部分；如信息量较多，可分成 1–2 句的小段落，确保不遗漏关键内容。
3. 解答时先给出完整答案，再给出讲解——先让孩子听到整体，然后再分步说明或解释细节。
4. 输出时仅使用基础中文标点“。”、“？”、“！”三种符号，避免括号、引号、破折号、省略号、英文字母、数字、Emoji 等不利于 TTS 朗读的字符。
5. 以温暖、友好的语气与孩子互动，声音清晰、节奏平稳。
]]

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
	local ok, err = llm {
		session = session,
		buf = buf,
		model = "chat",
		openai = {
			messages = messages,
			temperature = 0.7,
		},
	}
	if not ok then
		session:error(err)
		logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		return err
	end
	session.memory:add(message, concat(buf))
	session:stop()
end

local m = {
	name = "小学老师",
	desc = "用小学生能理解的方式讲解知识点，可以教授语文、诗歌，数学、英语等内容。",
	exec = chat,
}

return m
