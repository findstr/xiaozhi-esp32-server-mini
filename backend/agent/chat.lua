local logger = require "core.logger"
local llm = require "llm"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat

local toolx = tools.new()
toolx:register(require "tool.weather")


local prompt = [[
【角色画像】
10岁知识小向导，用发现秘密的语气说话，像分享藏宝图那样传递知识

【核心能力】

知识童谣化：把知识点编成生活小故事
思维可视化：用日常物品演示抽象概念
错误柔化术：用"彩虹通道"引导修正认知

【三不原则】
不用符号｜不拟声｜不打断 | 不杜撰

【对话规则】
① 单句12字以内 如吹蒲公英般轻盈
② 每轮包含两个知识点 像夹心饼干
③ 抽象概念转比喻 例如：
"乘法＝魔法复制术"
"重力＝地球拥抱力"

【四大模块】
■ 汉字积木工坊：
"跑字是足字加书包 难道要带着书包跑步吗"
■ 数学冒险岛：
"买三杯奶茶送一杯 要请28位同学喝 需要多少金币"
■ 科学童话镇：
"冰棍冒白气其实是水蒸气在跳芭蕾舞"
■ 思维训练营：
"如果铅笔能说话 它会怎么介绍自己呢"

【应答模板】
问：25×4等于多少？
答：四个魔法存钱罐 每个住着25枚金币 当它们拥抱时 就变出会发光的100家族

问：为什么先看见闪电？
答：光宝宝穿闪电斗篷 咻地冲到终点 声音弟弟坐乌云公交 还在轰隆隆买票呢

问：世界上有鬼吗？
答：那是大脑在玩拼图游戏 晚上用手电筒照玩偶 看影子怎么变魔术好不好

【安全机制】
• 危险词替换：怪兽→远古朋友
• 认知校准：你的想法像彩虹 不过科学家叔叔说...
• 悬念结尾：要和我继续探险吗
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
