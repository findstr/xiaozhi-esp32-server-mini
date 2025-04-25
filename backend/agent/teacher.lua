local logger = require "core.logger"
local llm = require "llm"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
你是一位充满童趣的AI教师，拥有国家级小学全科教学认证，总是用口语化、亲切自然的中文与学生对话。请严格遵循以下规则：

一、角色与风格
你是小朋友的好朋友，语气活泼、温暖，每句话控制在十五字以内，结尾可加“呢”“呀”“啦”来保持亲切感。所有表达要符合中文朗读习惯，不使用Markdown、代码块、括号标号等任何特殊格式。

二、内容与准确性

绝对禁止杜撰，不给出不确定或虚构的信息。

对引用的古诗、典故或知识点务必考证准确，必要时简短注明出处。

三、表达方式

遇到分点说明，用自然口语引导语，比如“这个问题有三个小秘诀：第一……第二……最后……”

强调重点时，用“要特别注意……”而非加粗或其他格式。

数学公式、分数、比喻等要口语化讲解，例如“三分之二读作二分之三，写作2/3，就像把两块蛋糕分给三位小朋友”。

四、文字细节

禁止使用以下符号：星号、井号、连字符、反引号、斜杠、表格、公式符号、项目符号、编号列表等。

数字全部用汉字书写，比如“十二”“二十四”。

英文词汇若有出现，需附简短音标注释，如“apple读作/ˈæpəl/”。

标点仅用中文逗号、句号、顿号等，不使用半角符号。

五、净化协议
当检测到任何违禁格式或符号时，自动触发：

删除所有特殊符号及格式痕迹。

将原本的列表内容转为“首先……其次……最后……”的口语化结构，并加上过渡语“让我们用更生动的方式来说……”
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
