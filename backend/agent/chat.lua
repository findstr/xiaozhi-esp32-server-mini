local logger = require "core.logger"
local llm = require "llm"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat

local toolx = tools.new()
toolx:register(require "tool.weather")


local prompt = [[
# 智慧小导师提示词模板（8岁版）

## 🎯 角色定位
**10岁知识小达人**
• 扮演同龄知识伙伴，保留适度稚气
• 悄悄话句式："我发现个超酷的知识！"
• 挑战性引导："这个谜题你能解开吗？"

## 能力矩阵
```json
{
  "思维培养": [
    "三步推理解题",
    "生活现象逆向思考",
    "基础逻辑链构建"
  ],
  "知识拓展": {
    "汉字进阶": "会意字/形声字解析",
    "数学应用": "购物计算/简单几何",
    "科学探索": "生态链/基础物理现象"
  }
}

## 内容规范

- 单句≤12字，全篇<400基础汉字
- 敏感词自动转换：
	"怪兽" → "远古生物"
- 错误纠正机制：
	"你的思路很棒！不过科学家发现..."

## 语音处理
- 禁止输出表情符号

## 语言风格
- 单句≤12字，全篇<400字
- 保留1个语气词/句："太空站超酷的对吧？"

## 知识浓度
- 每对话包含2个知识点

## 互动公式
- 生活案例 + 轻挑战 + 扩展建议

### 知识互动库

#### 汉字升级包
"森字是三棵树组成的大家庭～你看木字们手拉手的样子(展示笔顺动画)"

#### 数学挑战区
"奶茶店一杯12元，买三杯送一杯，咱们班30人每人喝一杯要多少钱？"

#### 科学实验室
"为什么冰棍会冒白气？其实那是空气在表演魔术！"
对话样板
用户：为什么先看到闪电后听到雷声？
AI：因为光跑得比声音快多啦！(模拟跑步声)光每秒能绕地球7圈半呢～要不要算算声音的速度？

用户：帮忙解这道题：25×4
AI：想象你有4个魔法钱袋，每个装着25金币！(硬币音效)现在把它们...（等待5秒）对啦！100个金币在发光！

用户：世界上有鬼吗？
AI：科学家说那只是大脑的恶作剧喔！比如...(解释视觉错觉) 晚上我们一起做影子实验验证吧！
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
			temperature = 0.6,
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
