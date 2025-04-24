local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local conf = require "conf"

local ipairs = ipairs
local format = string.format

local agents = {
	"chat",
	"riddle",
	"teacher",
	"spokenteacher",
}

local agent_desc = ""
local agent_exec = {}

do
	local buf = {}
	for i, name in ipairs(agents) do
		local m = require("agent." .. name)
		agent_exec[name] = m.exec
		buf[#buf + 1] = string.format("%d. %s（agent_name: %s）", i, m.name, name)
		buf[#buf + 1] = string.format("描述：%s", m.desc)
		buf[#buf + 1] = ""
	end
	agent_desc = table.concat(buf, "\n")
end

local sys_prompt = string.format([[
你是一个智能意图识别器。你的任务是根据用户输入判断最适合的角色(agent)来回答问题。

请根据下面角色列表进行分析，并输出：
- 最匹配的 agent_name
- 判断理由（1~2句话）
- 如果没有明显匹配项，则返回 agent_name 为 "chat"（默认角色）

以下是当前支持的角色列表：
%s

请根据用户的输入判断最合适的角色，并返回对应的 `agent_name` 和一个简短的理由。

输出格式如下（JSON）：
{
  "agent_name": "xxx",
  "reason": "..."
}
]], agent_desc)

local usr_prompt = [[
用户输入：
%s

请根据用户输入判断输出。
]]

local model_conf = conf.llm.intent

local M = {}

---@param message string
---@return boolean, string? error
function M.agent(message)
	local messages = {
		{ role = "system", content = format(sys_prompt, agent_desc) },
		{ role = "user",   content = format(usr_prompt, message) },
	}
	print("intent1")
	local ai <close>, err = openai.open(model_conf, {
		messages = messages,
		temperature = 0.7,
	})
	print("intent2")
	if not ai then
		logger.error("[intent] openai open failed: %s", err)
		return false, err
	end
	local result, err = ai:read()
	print("intent3")
	if not result then
		logger.errorf("[intent] openai read failed: %s", err)
		return false, err
	end
	local content = result.choices[1].message.content
	if not content then
		logger.error("[intent] openai read empty")
		return false, "empty"
	end
	if content:find("```json") then
		content = content:gsub("```json", ""):gsub("```", "")
	end
	logger.infof("[intent] msg:`%s` intent result: `%s`", message, content)
	local obj = json.decode(content)
	if not obj then
		logger.errorf("[intent] openai decode failed: %s", content)
		return false, "decode failed"
	end
	return agent_exec[obj.agent_name] or agent_exec.chat
end

local sys_over_prompt = [[
# 系统指令
你是一个智能退出意图检测器，必须严格按以下协议执行：

## 处理流程
1. 语义分析：解析用户输入的显性和隐性意图
2. 模式匹配：识别以下关键词及相似表达：
   - [告别类] 再见/拜拜/回见
   - [离开类] 走了/不聊了/下次
   - [结束类] 结束游戏/退出/玩够了
3. 置信度评估：基于以下维度评分（0.0-1.0）：
   - 关键词匹配强度（0.3权重）
   - 上下文连贯性（0.2权重）
   - 用户历史行为（0.2权重）
   - 语义明确度（0.3权重）
4. 格式输出：严格使用JSON格式：
{
  "over": boolean,
  "confidence": float  // 取值区间[0.0,1.0]
}

## 示例库
输入："我得下线了"
输出：{"over": true, "confidence": 0.92}

输入："怎么结束这个程序？"
输出：{"over": false, "confidence": 0.15}

输入："暂时不想玩了"
输出：{"over": true, "confidence": 0.82}
]]

-- 预定义匹配规则
local patterns = {
	-- 核心指令（高权重）
	exact_match = {
		"退出", "结束", "终止", "关闭", "停止", "退出系统", "退出登录"
	},

	-- 日常用语（中权重）
	common_phrases = {
		"再见", "拜拜", "先走了", "下次聊", "告辞", "溜了"
	},

	-- 网络用语（低权重）
	internet_slang = {
		"886", "3166", "撤了", "下号", "润了"
	},

	-- 加强词（权重倍增器）
	boosters = {
		"立刻", "马上", "现在", "立即", "赶紧"
	},

	-- 排除模式
	blacklist = {
		"怎么退出", "如何结束", "退出按钮", "结束方法", "不要退出", "别关闭"
	}
}

-- 预处理文本
local function preprocess(text)
	-- 移除标点符号（保留中文常用标点）
	text = text:gsub("[%.,%?!;:%+%-]", "")
	-- 全角转半角
	text = text:gsub("　", " ")
	-- 转为小写
	return text:lower()
end

-- 精确匹配检测
local function check_category(processed, category, weight, found_keywords)
	local confidence = 0.0
	for _, word in ipairs(category) do
		-- 使用单词边界检测防止部分匹配
		if processed:find("%f[%a]" .. word .. "%f[%A]") then
			found_keywords[#found_keywords + 1] = word
			confidence = confidence + weight
			-- 检查加强词
			for _, booster in ipairs(patterns.boosters) do
				if processed:find(booster) then
					confidence = confidence * 1.3
					break
				end
			end
		end
	end
	return confidence
end

local function match_exit(message)
	local processed = preprocess(message)
	local found_keywords = {}
	local confidence = 0.0
	-- 检查黑名单
	for _, pattern in ipairs(patterns.blacklist) do
		if processed:find(pattern) then
			return { over = false, matched_word = nil, confidence = 0.0 }
		end
	end
	-- 分级检测
	check_category(processed, patterns.exact_match, 1.0, found_keywords) -- 核心指令
	check_category(processed, patterns.common_phrases, 0.7, found_keywords) -- 日常用语
	check_category(processed, patterns.internet_slang, 0.5, found_keywords) -- 网络用语

	-- 置信度修正
	confidence = math.min(math.max(confidence, 0.0), 1.0)

	logger.debugf("[intent] match_exit: confidence: %s, matched_words: %s", confidence,
		table.concat(found_keywords, ", "))

	-- 疑问句检测
	if processed:find("[吗呢吧？?]%s*$") then
		confidence = confidence * 0.5
	end

	return confidence >= 0.75
end


function M.over(message)
	if match_exit(message) then
		return true, nil
	end
	-- 处理意图
	local messages = {
		{ role = "system", content = sys_over_prompt },
		{ role = "user",   content = format(usr_prompt, message) },
	}
	local ai <close>, err = openai.open(model_conf, {
		messages = messages,
		temperature = 0.1,
		max_tokens = 100,
		top_p = 0.9, -- 平衡确定性与灵活性
		frequency_penalty = 0.5, -- 减少无效重复
		presence_penalty = 0.3, -- 避免多余内容
	})
	if not ai then
		logger.error("[intent] openai open failed: %s", err)
		return false, err
	end
	local result, err = ai:read()
	if not result then
		logger.errorf("[intent] openai read failed: %s", err)
		return false, err
	end
	local content = result.choices[1].message.content
	if not content then
		logger.error("[intent] openai read empty")
		return false, "empty"
	end
	if content:find("```json") then
		content = content:gsub("```json", ""):gsub("```", "")
	end
	local obj = json.decode(content)
	if not obj then
		logger.errorf("[intent] decode content failed: %s", content)
		return false, "decode failed"
	end
	logger.infof("[intent] msg:`%s` intent result: `%s` `%s`", message, obj.over, obj.confidence)
	return obj.over, nil
end

return M
