local json = require "core.json"
local openai = require "openai"
local concat = table.concat
local format = string.format
local conf = require "conf"

local level_prompt = [[
# 需求
请基于以下元素生成1个中文RPG式英语学习关卡：
- 妖怪名称: %s
- 妖怪描述: %s
- 英文句子：%s

# 要求
## 核心要素
1. 场景沉浸感：
   - 每个关卡需包含30-50字的场景描写
   - 场景需包含：环境特征 + 敌人登场方式 + 敌人说出英文句子来考验玩家, 注意：敌人只会说出给定的英文句子来考验玩家, 除此之外不会说多余的英文, 并且英文总是在最后
   - 结合妖怪特性设计互动元素（如火焰妖怪配燃烧场景）

## 格式规范
{
"场景描述": "", // 包含环境/登场/挑战三要素
}
]]
local check_prompt = [[
# 需求
请校验以下英语对话的合理性：
- 妖怪问句："%s"
- 玩家答句："%s"

# 校验规则
1. 正确标准：
   - 语法正确
   - 逻辑连贯
   - 语境匹配

2. 反馈要求：
   - **正确时**：生成带有妖怪特性的RPG式夸奖，例如：
     > "哼哼，人类居然能说出如此流畅的话语，看来你已经摸到了异界智慧的门槛！"
   - **错误时**：
     - 依然以妖怪的口吻进行点评，而不是普通的中文讲解。
     - 说明玩家回答的问题出在哪里，并给出正确范例。
     - 然后鼓励玩家再试一次
     - 示例：
       > "哼哼，你闯关失败了! [详细的错误原因并拿自身举例], 再给你一次机会吧"

# 输出格式
```json
{
  "correct": true/false,
  "teaching": "反馈内容"
}
]]

level_prompt = level_prompt:gsub("\n", "\\n")
check_prompt = check_prompt:gsub("\n", "\\n")

local sys_prompt = [[你是创造性的英语教学游戏设计师，专门创建有趣的中文场景来帮助用户练习英语口语。]]



local function create_level(sentence, monster)
	local prompt = format(level_prompt, monster.name, monster.desc, sentence)
	local messages = {
		{role = "system", content = sys_prompt},
		{role = "user", content = prompt},
	}
	local ai<close>, err = openai.open {
		llm = "think",
		messages = messages,
		temperature = 0.9,
	}
	local buf = {}
	while true do
		local obj, err = ai:read()
		if not obj then
			print("create_level finished:", err)
			break
		end
		local choice = obj.choices[1]
		local content = choice.delta.content
		buf[#buf + 1] = content
	end
	local content = concat(buf)
	content = content:gsub("\\n", "\n")
	print(content)
	return json.decode(content)
end

local function check_level(monster, sentence, answer)
	local prompt = format(check_prompt, sentence, answer)
	local messages = {
		{role = "system", content = sys_prompt},
		{role = "user", content = prompt},
	}
	local ai<close>, err = openai.open {
		llm = "think",
		messages = messages,
		temperature = 0.9,
	}
	local buf = {}
	while true do
		local obj, err = ai:read()
		if not obj then
			break
		end
		local choice = obj.choices[1]
		local content = choice.delta.content
		buf[#buf + 1] = content
	end
	local content = concat(buf)
	content = content:gsub("\\n", "\n")
	print(content)
	return json.decode(content)
end

local monsters = {
	{
		name = "黑熊精",
		desc = "在西游记中，黑熊精偷了唐三藏的袈裟，被孙悟空打败后，被观音菩萨收为徒弟，成为唐僧的徒弟。"
	},
	{
		name = "白骨精",
		desc = "在西游记中，白骨精偷了唐三藏的袈裟，被孙悟空打败后，被观音菩萨收为徒弟，成为唐僧的徒弟。"
	},
}

local sentences = {
	"how are you",
	"what is your name",
	"how old are you",
	"what is your job",
	"what is your hobby",
}

local user_level = setmetatable({}, {__mode = "k"})

local function chat(agent, message)
	local level = user_level[agent]
	if not level then
		local mi = math.random(1, #monsters)
		local si = math.random(1, #sentences)
		local monster = monsters[mi]
		local sentence = sentences[si]
		local desc, err = create_level(sentence, monster)
		if not desc then
			return nil
		end
		local scene = desc["场景描述"]
		level = {
			scene = scene,
			sentence = sentence,
			monster = monster,
		}
		user_level[agent] = level
		return scene
	end
	local check, err = check_level(level.monster, level.sentence, message)
	if not check then
		return err
	end
	return check.teaching
end
local x = json.decode([[{"id":"202503071734054a76dc106bd642e2","created":1741340045,"model":"glm-4-flash","choices":[{"index":0,"delta":{"role":"assistant","content":"\\"}}]}]])
print("-=:", x)
--[[
local x = {}
for i = 1, 10 do
	chat(x, "how are you")
	core.sleep(1000)
	print("----")
	chat(x, sentences[math.random(1, #sentences)])
	core.sleep(1000)
end
]]
return chat
