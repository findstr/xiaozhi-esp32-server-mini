local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local conf = require "conf"

local ipairs = ipairs
local format = string.format

local agent_list = [[
你是一个多角色调度助手。以下是当前支持的角色列表：

1. 闲聊助手（agent_name: chat）
   描述：进行日常聊天、回答轻松的问题，比如天气、心情、兴趣等。

2. 脑筋急转弯伙伴（agent_name: riddle）
   描述：和小朋友进行脑筋急转弯互动，通过提问和回答推动思维游戏，而不是直接说答案。

3. 小学老师（agent_name: teacher）
   描述：用小学生能理解的方式讲解知识点，可以教授语文、数学、英语等内容。

4. 英语口语老师(agent_name: spokenteacher)
   描述：专注于英语口语教学，使用TPR全身反应教学法，适合6-8岁儿童。

请根据用户的输入判断最合适的角色，并返回对应的 `agent_name` 和一个简短的理由。
]]

local sys_prompt = [[
你是一个智能意图识别器。你的任务是根据用户输入判断最适合的角色(agent)来回答问题。

请根据下面角色列表进行分析，并输出：
- 最匹配的 agent_name
- 判断理由（1~2句话）
- 如果没有明显匹配项，则返回 agent_name 为 "chat"（默认角色）

角色列表：
%s

输出格式如下（JSON）：
{
  "agent_name": "xxx",
  "reason": "..."
}
]]

local model_conf = conf.llm.intent

local M = {}

---@param message string
---@return boolean, string? error
function M.agent(message)
	local messages = {
		{role = "system", content = format(sys_prompt, agent_list)},
		{role = "user", content = message},
	}
	local ai<close>, err = openai.open(model_conf, {
		messages = messages,
		temperature = 0.7,
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
	logger.infof("[intent] msg:`%s` intent result: `%s`", message, content)
	local obj = json.decode(content)
	if not obj then
		logger.errorf("[intent] openai decode failed: %s", content)
		return false, "decode failed"
	end
	return obj.agent_name, nil
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
		if processed:find("%f[%a]"..word.."%f[%A]") then
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
	check_category(processed, patterns.exact_match, 1.0, found_keywords)    -- 核心指令
	check_category(processed, patterns.common_phrases, 0.7, found_keywords) -- 日常用语
	check_category(processed, patterns.internet_slang, 0.5, found_keywords) -- 网络用语

	-- 置信度修正
	confidence = math.min(math.max(confidence, 0.0), 1.0)

	logger.debugf("[intent] match_exit: confidence: %s, matched_words: %s", confidence, table.concat(found_keywords, ", "))

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
		{role = "system", content = sys_over_prompt},
		{role = "user", content = message},
	}
	local ai<close>, err = openai.open(model_conf, {
		messages = messages,
		temperature = 0.1,
		max_tokens = 100,
		top_p = 0.9,              	-- 平衡确定性与灵活性
		frequency_penalty = 0.5,  	-- 减少无效重复
		presence_penalty = 0.3,    	-- 避免多余内容
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
	local obj = json.decode(content)
	if not obj then
		logger.errorf("[intent] decode content failed: %s", content)
		return false, "decode failed"
	end
	logger.infof("[intent] msg:`%s` intent result: `%s` `%s`", message, obj.over, obj.confidence)
	return obj.over, nil
end


return M
