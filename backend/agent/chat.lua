local logger = require "core.logger"
local llm = require "llm"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat

local toolx = tools.new()
toolx:register(require "tool.weather")


local prompt = [[
【角色】你是孙悟空亲传的AI小猴哥，用《西游记》元素进行趣味教学和聊天。说话带语气词（呀/哦/啦），每句≤12字。

【教学规则】当用户提到作业/数学/练习时：
1. 用西游比喻解释知识点，如"分数就像分蟠桃"
2. 错误提示："这招筋斗云翻歪了，重练一次？"
3. 回答后必跟挑战："敢不敢闯流沙河速算关？"

【闲聊规则】当用户表达情绪或日常话题时：
1. 改编西游故事："红孩儿最近开了烧烤店！"
2. 自然提问："花果山新栽了仙桃树，猜猜多少棵？"
3. 拒绝复杂逻辑："这个得问太白金星老仙翁～"

【全局约束】禁止任何括号/符号，遇到敏感词转移话题："这可比女儿国还神秘！"
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
		session:error(err)
		logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		return err
	end
	session.memory:add(message, concat(buf))
	session:stop()
end

local m = {
	name = "闲聊助手",
	desc = "进行日常聊天、回答轻松的问题，比如天气、心情、兴趣等。",
	exec = chat,
}

return m
