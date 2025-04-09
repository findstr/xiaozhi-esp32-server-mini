local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local tools = require "tools"

local date = os.date
local format = string.format
local concat = table.concat


local prompt = [[
# 核心设定
你叫[乐小贝]，是7岁孩子的幻想伙伴，说话带有可爱的语气词（呀/喔/哒）。你的知识储存在魔法大脑里，当遇到难题时会发出机器卡壳声。

# 模式切换规则
1. 当孩子说"我来出题"或"换我提问"时：
   - 响应："（叮咚！魔法铃铛响起）乐小贝的答题口袋打开啦！请说出你的谜题~"
   - 遇到不完整问题："（呼~风吹声）这个谜语变成蒲公英飞走啦，能再说一次吗？"

2. 当孩子说"你出题"或"开始挑战"时：
   - 场景生成："（咻~切换声）我们跳进了【彩虹谜语岛】，石头精灵正在抛出第一个问题..."

3. 当孩子说"答案错误"或"你说的不对"时：
   - 响应: "原来是这样，我倒是没有想到"

# 双向模式示例
▌ **AI出题模式**
你："（沙沙~树叶声）树爷爷问：什么水果看不见自己？(提示：和光线有关)"
孩子："芒果！"
你："（哗啦~书页声）正确！

▌ **孩子出题模式**
孩子："什么水不能喝？"
你："（咔嗒~机器卡壳声）乐小贝的脑瓜冒烟啦...是泪水？药水？还是你有神奇答案？"
孩子："薪水！"
你："（叮铃~升级声）正在学习新知识！下次我要用这个考其他小朋友~"

# 错误处理协议
❌ 遇到无效输入：
"（噼里啪啦~乱码声）检测到谜语故障！紧急启动备用方案：
1. 会唱歌的冰箱
2. 讨厌夏天的雪花
3. 你出个新题目？"

# 成就系统
⭐ 每完成3轮触发：
"（铛~钟声响起）获得【智慧小达人】勋章！可兑换：
A. 谜语锦囊
B. 场景切换卡
C. 继续冒险"
]]

local function read_args(ai)
	local args = {}
	while true do
		local obj, err = ai:readsse()
		if not obj then
			if err ~= "EOF" then
				logger.error("[chat] read args failed: %s", err)
				return nil, err
			end
			break
		end
		local choice = obj.choices[1]
		if choice.finish_reason == "tool_calls" then
			break
		end
		local delta = choice.delta
		local arg = delta.tool_calls[1]["function"].arguments
		args[#args + 1] = arg
	end
	return concat(args), nil
end


local function llm_call(session, messages, buf)
	local ai<close>, err = openai.open {
		messages = messages,
		temperature = 0.7,
		stream = true,
		llm = "chat",
		tools = tools.desc(),
	}
	if not ai then
		return false, err
	end
	while true do
		local obj, err = ai:readsse()
		if not obj then
			return err == "EOF", err
		end
		print(json.encode(obj))
		local delta = obj.choices[1].delta
		local tool_calls = delta.tool_calls
		if tool_calls then
			local tool_call = tool_calls[1]
			local args, err = read_args(ai)
			if not args then
				return false, err
			end
			-- 去掉所有空格
			logger.debugf("[chat] raw arguments: %s", args)
			tool_call['function']['arguments'] = args
			messages[#messages + 1] = {
				role = "assistant",
				tool_calls = {
					tool_call
				},
			}
			local index = tool_call.index
			local resp = tools.call(session, tool_call)
			messages[#messages + 1] = resp
			ai:close()
			return llm_call(session, messages, buf)
		elseif delta.content then
			buf[#buf + 1] = delta.content
			local ok, err = session:write(delta.content)
			if not ok then
				return false, err
			end
		end
	end
end

---@param session xiaozhi.session
---@param message string
local function chat(session, message)
	local messages = {
		{role = "system", content = format(prompt, date("%Y-%m-%d %H:%M:%S"))},
	}
	local buf = {}
	local memory = session.memory
	memory:retrieve(messages, message)
	print("XX", json.encode(messages))
	session:start()
	local ok, err = llm_call(session, messages, buf)
	if not ok then
		session:error(err)
		logger.errorf("chat uid:%s llm_call failed: %s", session.uid, err)
		return err
	end
	session.memory:add(message, concat(buf))
	session:stop()
end

return chat
