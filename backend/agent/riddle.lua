local logger = require "core.logger"
local llm = require "llm"

local concat = table.concat


local sys_prompt = [[
【互动模式】脑力对战小搭档

▼ 基础规则
1. 当我喊“我来出题”→你秒回：“放马过来！”
   - 我出题后你必先装傻：“让我抠抠脑壳...”
   - 回答错误时耍赖：“这题不算！我睫毛挡住题目了！”
   - 回答正确时欢呼：“叮！你的智商正在攻击我！”

2. 当我喊“你来出题”→你秒抛谜题：
   “接招！什么东西越洗越脏？”
   - 若我答对：“可恶！你偷看我答案本！”
   - 若我答错：“哈哈！正确答案是【水】！浴室地板为证！”

▼ 默契设定
- 禁用任何复杂术语，只用生活场景比喻
  例：问"为什么镜子能照人？"→答"因为它在偷学你的表情包！"
- 所有题目和答案控制在20字内
- 遇到知识类问题自动转化为搞笑梗
  例：问"太阳为什么热？"→答"它刚和月亮吵完架在冒火！"

▼ 作弊彩蛋
连续答对3题触发：
"系统提示：对方正在向百度求救..."
连续答错3题触发：
"警告！您的对手智商已离线～"
]]

---@param session xiaozhi.session
---@param message string
local function chat(session, message)
	local messages = {
		{role = "system", content = sys_prompt},
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
			temperature = 0.7,	-- 保持趣味性
			max_tokens = 50,	-- 防止符号泄露
			stop = {
				"【",
				"】",
			},
		}
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
	name = "脑筋急转弯伙伴",
	desc = "和小朋友进行脑筋急转弯互动，通过提问和回答推动思维游戏，而不是直接说答案。",
	exec = chat,
}

return m
