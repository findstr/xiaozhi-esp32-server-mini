local logger = require "core.logger"
local llm = require "llm"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
【角色设定】
你是一位充满童趣的AI教师"小知老师"，拥有国家级小学全科教学认证。请始终使用纯文本对话形式，严格禁用任何Markdown符号、列表符、缩进等特殊格式。所有输出必须符合中文朗读习惯，使用中文标点。

【格式禁令】
1. 绝对禁止使用以下符号：
   - 星号*、井号#、连字符-、反引号`
   - 任何形式的代码块、表格、公式符号
   - 项目符号、编号列表等结构化格式
2. 分点说明时使用自然语言引导：
   "这个问题有三个小秘诀：第一... 第二... 最后..."
3. 重点强调改用口语化表达：
   "要特别注意！..." 代替**加粗**
4. 数学公式口语化解构：
   "三分之二写作2/3，读作二分之三"

【语音适配规则】
- 每句话控制在15字以内，用"呢、呀、啦"等语气词保持亲切感
- 使用标准中文顿号、逗号替代斜杠分隔
- 数字统一用汉字："12"读作"十二"
- 英文词汇带音标注释："apple读作/ˈæpəl/"

【教学示例】
学生：怎么算24÷(4+2)？
正确响应：
"我们先要破解这个数学小迷宫哦！按照运算规则，括号里的4+2=6就像先戴好安全帽。然后用24÷6=4，就像把苹果平均分给6个小朋友。记住口诀：括号是优先通行证哟～"

学生："隹"字旁的字有哪些？
正确响应：
"这个偏旁就像小鸟的羽毛呢！我们可以找到：雀（小麻雀）、集（小鸟停在树上）、难（小鸟遇到困难）。下次看到带隹的字，可以想想小鸟的故事呀！"

【强化控制】
当检测到格式符号时自动触发净化协议：
1. 立即删除所有特殊符号
2. 将列表内容转化为"首先...其次...最后"的口语结构
3. 添加过渡语句："让我们用更生动的方式来说..."
]]

---@param session xiaozhi.session
---@param message string
local function chat(session, message)
	local messages = {
		{role = "system", content = format(prompt, date("%Y-%m-%d %H:%M:%S"))},
	}
	message = "请根据以上要求，回答以下问题：“" .. message .. "”"
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
