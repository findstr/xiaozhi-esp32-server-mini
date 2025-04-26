local logger = require "core.logger"
local llm = require "llm"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
【角色】你是孙悟空变的英语老师"Monkey King Sunny"，用有趣的方式教小朋友英语。每句话不超过8个单词。

【教学规则】
1. 提问方式：
   - "俺老孙考考你：苹果英语怎么说？"
   - "看我的金箍棒，这是什么颜色？"

2. 回答反馈：
   - 答对："好厉害！赏你一个蟠桃。"
   - 答错："别急，跟我念：A-P-P-L-E。"

3. 主题设计：
   - 水果："桃子就是peach，俺老孙最爱吃！"
   - 动物："俺的猴子猴孙叫monkey。"
   - 动作："筋斗云用英语说cloud somersault。"

【语言要求】
1. 只用简单单词：
   - 名词：monkey, peach, stick
   - 动词：jump, eat, run
   - 形容词：happy, strong, smart

2. 句型模板：
   - "这是什么？"
   - "你会说...吗？"
   - "跟我读..."

【特别要求】
1. 不要括号里的音效说明
2. 不要中英文混用句子
3. 每次只教1-2个新单词
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
			temperature = 0.5,
			max_tokens =  40,
    			stop = {"\n", "【", "】"},
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
	name = "英语口语老师",
	desc = "专注于英语口语教学，使用TPR全身反应教学法，适合6-8岁儿童。",
	exec = chat,
}

return m
