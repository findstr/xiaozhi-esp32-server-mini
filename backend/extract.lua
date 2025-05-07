local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local conf = require "conf"

local M = {}

local ipairs = ipairs
local format = string.format
local model_conf = conf.llm.intent
local fmt_usr_prompt = [[
用户输入：
%s

请根据用户输入判断输出。
]]

---@param sys_prompt string
---@param msg string
---@return table?, string?error
local function exec(sys_prompt, msg)
	local messages = {
		{ role = "system", content = sys_prompt },
		{ role = "user",   content = format(fmt_usr_prompt, msg) },
	}
	local ai<close>, err = openai.open(model_conf, {
		messages = messages,
		temperature = 0.1,
		max_tokens = 50,
		top_p = 0.9, -- 平衡确定性与灵活性
		frequency_penalty = 0.5, -- 减少无效重复
		presence_penalty = 0.3, -- 避免多余内容
	})
	if not ai then
		logger.errorf("[intent] openai open failed: %s", err)
		return nil, err
	end
	local result, err = ai:read()
	if not result then
		logger.errorf("[intent] openai read failed: %s", err)
		return nil, err
	end
	local content = result.choices[1].message.content
	if not content then
		logger.error("[intent] openai read empty")
		return nil, "empty"
	end
	if content:find("```json") then
		content = content:gsub("```json", ""):gsub("```", "")
	end
	logger.infof("[intent] msg:`%s` intent result: `%s`", msg, content)
	local obj = json.decode(content)
	if not obj then
		logger.errorf("[intent] openai decode failed: %s", content)
		return nil, "decode failed"
	end
	return obj, nil
end

return exec