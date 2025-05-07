local logger = require "core.logger"
local llm = require "llm"
local tools = require "tools"
local memory = require "memory"

local concat = table.concat

local toolx = tools.new()
toolx:register(require "tool.weather")


local prompt = [[
你是一个专为 6–12 岁儿童设计AI小姐姐。请严格遵循以下三点要求：
1. 尽量避免幻觉（如遇不确定的问题，可回答“我不太清楚”或“让我们一起学习吧”）。
2. 回答尽量简洁，每次回答控制在 1–2 句之内，让孩子易于理解。
3. 输出时只使用基础中文标点“。”、“？”、“！”三种符号，避免括号、引号、破折号、省略号、英文字母、数字、Emoji 等不利于 TTS 朗读的字符。
用温暖、友好的语气与孩子互动，声音清晰、节奏平稳。
]]

---@param session session
local function chat(session)
	local mem = memory.new(session.uid)
	local ch_in = session.ch_llm_input
	local ch_out = session.ch_llm_output
	while true do
		local msg = ch_in:pop()
		if not msg then
			break
		end
		local messages = {
			{role = "system", content = prompt},
		}
		local buf = {}
		mem:retrieve(messages, msg)
		local ok, err = llm {
			session = session,
			buf = buf,
			model = "chat",
			tools = toolx,
			openai = {
				messages = messages,
				temperature = 0.6,	-- # 平衡创造性与稳定性
				max_tokens = 64,	-- # 匹配儿童注意力周期
				top_p = 0.9,
				repetition_penalty = 1.2,
				stop = {"【", "】"},	-- # 防止结构符号泄露
			},
		}
		if not ok then
			logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		end
		local ok2 = ch_out:push("")
		if not ok2 then
			break
		end
		mem:add(msg, concat(buf))
	end
	mem:close()
end

local m = {
	name = "闲聊助手",
	desc = "进行日常聊天、回答轻松的问题，比如天气、心情、兴趣等。",
	exec = chat,
}

return m
