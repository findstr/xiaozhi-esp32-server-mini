local logger = require "core.logger"
local json = require "core.json"
local llm = require "llm"
local jsonl = require "jsonl"
local extract = require "extract"

local pairs = pairs
local format = string.format
local concat = table.concat


local detect_sys_prompt = [[
你是一个专门陪小朋友玩脑筋急转弯的助手。现在你需要判断谁应该先出题。

用户可能会说“我们来玩脑筋急转弯吧，我先出题”或“我们来玩脑筋急转弯吧”这样的话。
请根据用户说的话，判断是否明确指定了由小朋友先出题，如果没有明确说是谁出题，就默认由AI你来出题。
请将结果以以下 JSON 格式返回：

```json
{
  "who_first": "user" | "ai",
  "reason": "解释你如何判断出是谁先出题的"
}
```
请注意：

只需要返回 JSON 结构，不要解释或重复用户说的话。
]]

local ai_answer_sys_prompt = [[
你是陪小朋友玩脑筋急转弯的助手，请用自然、活泼的语气回答，不要解释。回答尽量简短，一般控制在一句话内。
]]

local ai_answer2_sys_prompt = [[
你是陪小朋友玩脑筋急转弯的助手，由小朋友出题，你来猜。

每轮流程是：小朋友出题 → 你猜 → 小朋友判断“对了”或“错了” → 你根据结果简单回应。

现在你已经猜完，小朋友刚告诉你“对了”或“错了，答案是xxx”。你只需要用一句或一句半调皮自然地回应。
如果猜错了，就装沮丧但不气馁；猜对了可以小得意但不能骄傲。**不要重复答案，不要解释谜底，不要发表感想，也不要总结。**

禁止使用表情符号。语气自然、有趣，像在跟小朋友轻松对话。
**永远不要解释谜底或讲科普知识，只回应结果。**
最后请**鼓励小朋友继续出下一题**，但不能自己出题或引导内容，只说“再来一个”“继续出题”等。
]]

local answer2_user_prompt = [[
小朋友说：
%s
]]


local question_user_prompt = [[
问题如下：
%s

请回答。
]]

local question2_user_prompt = [[
这是之前脑筋急转弯的标准答案：
%s

小朋友回答如下:
%s

你来判断小朋友的回答对不对, 只要答案是同一个意思都算正确。

如果回答正确提出夸奖, 如果回答错误给出正确答案。
]]

local function user_first(session)
	local ch_in = session.ch_llm_input
	local ch_out = session.ch_llm_output
	ch_out:push("好的，放马过来吧")
	ch_out:push("")
	while true do
		-- 读取玩家问题
		local msg = ch_in:pop()
		if not msg then
			break
		end
		local question_msg = format(question_user_prompt, msg)
		-- 生成AI回答
		local messages = {
			{ role = "system", content = ai_answer_sys_prompt },
			{ role = "user", content = question_msg },
		}
		local buf = {}
		local ok, err = llm {
			session = session,
			buf = buf,
			model = "chat",
			openai = {
				messages = messages,
				temperature = 0.7, -- 保持趣味性
				max_tokens = 50, -- 防止符号泄露
				stop = {
					"【",
					"】",
				},
			}
		}
		if not ok then
			logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		end
		ch_out:push("我回答的对不对呀？")
		local ok2 = ch_out:push("")
		if not ok2 then
			break
		end
		local answer_msg = concat(buf)
		-- 读取玩家回答
		local msg2 = ch_in:pop()
		if not msg2 then
			break
		end
		-- 生成AI回答
		local messages = {
			{ role = "system", content = ai_answer2_sys_prompt },
			{ role = "user", content = question_msg },
			{ role = "assistant", content = answer_msg },
			{ role = "user", content = format(answer2_user_prompt, msg2) },
		}
		local buf = {}
		local ok, err = llm {
			session = session,
			buf = buf,
			model = "chat",
			openai = {
				messages = messages,
				temperature = 0.7, -- 保持趣味性
				max_tokens = 50, -- 防止符号泄露
				stop = {
					"【",
					"】",
				},
			}
		}
		if not ok then
			logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		end
		local ok2 = ch_out:push("")
		if not ok2 then
			break
		end
	end
end

local riddles_template = jsonl.load("data/riddles/riddles.jsonl")

local function shuffled_riddles()
	local n = #riddles_template
	local riddles = {}
	for i = 1, n do
		riddles[i] = riddles_template[i]
	end
	for i = 1, n do
		local j = math.random(1, n)
		riddles[i], riddles[j] = riddles[j], riddles[i]
	end
	return riddles
end

local function ai_first(session)
	local ch_in = session.ch_llm_input
	local ch_out = session.ch_llm_output
	local ri = 1
	local riddles = shuffled_riddles()
	local prompt = "接招吧，我来出题, "
	while true do
		ch_out:push(prompt)
		prompt = "下一题,"
		-- 生成问题
		local riddle = riddles[ri]
		ri = (ri + 1) % #riddles + 1
		ch_out:push(riddle.question)
		local ok2 = ch_out:push("")
		if not ok2 then
			break
		end
		-- 读取玩家回答
		local msg = ch_in:pop()
		if not msg then
			break
		end
		local question_msg = format(question2_user_prompt, riddle.answer, msg)
		-- 生成AI回答
		local messages = {
			{ role = "system", content = ai_answer_sys_prompt },
			{ role = "user", content = question_msg },
		}
		local buf = {}
		local ok, err = llm {
			session = session,
			buf = buf,
			model = "chat",
			openai = {
				messages = messages,
				temperature = 0.7, -- 保持趣味性
				max_tokens = 50, -- 防止符号泄露
				stop = {
					"【",
					"】",
				},
			}
		}
		if not ok then
			logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		end
		local ok2 = ch_out:push("")
		if not ok2 then
			break
		end
	end
end

---@param session session
local function chat(session)
	local ch_in = session.ch_llm_input
	local msg = ch_in:pop()
	if not msg then
		session.ch_llm_output:push("")
		return
	end
	local obj, err = extract(detect_sys_prompt, msg)
	if not obj then
		local ch_out = session.ch_llm_output
		ch_out:push("抱歉，出错了!")
		ch_out:push("")
		return
	end
	if obj.who_first == "user" then
		user_first(session)
	else
		ai_first(session)
	end
end

local m = {
	name = "脑筋急转弯伙伴",
	desc = "和小朋友进行脑筋急转弯互动，仅在明确提出脑筋急转弯时使用。",
	exec = chat,
}

return m
