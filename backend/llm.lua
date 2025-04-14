local logger = require "core.logger"
local json = require "core.json"
local openai = require "openai"
local conf = require "conf"
local concat = table.concat

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

---@param args {
---	model: string,
---	tools: tools,
---	session: xiaozhi.session,
---	buf: string[],
---	openai: table,
---}
local function llm_call(args)
	local model_conf = conf.llm[args.model]
	if not model_conf then
		return false, "model not found: " .. args.model
	end
	local tools = args.tools
	local session = args.session
	local buf = args.buf
	local openai_args = args.openai
	if tools then
		openai_args.tools = tools:desc()
	end
	openai_args.stream = true
	local ai, err = openai.open(model_conf, openai_args)
	if not ai then
		return false, err
	end
	local messages = openai_args.messages
	while true do
		local obj, err = ai:readsse()
		if not obj then
			return err == "EOF", err
		end
		logger.debugf("[llm] readsse: %s", json.encode(obj))
		local delta = obj.choices[1].delta
		local tool_calls = delta.tool_calls
		if tool_calls then
			local tool_call = tool_calls[1]
			local call_args, err = read_args(ai)
			if not call_args then
				return false, err
			end
			-- 去掉所有空格
			logger.debugf("[chat] raw arguments: %s", call_args)
			tool_call['function']['arguments'] = call_args
			messages[#messages + 1] = {
				role = "assistant",
				tool_calls = {
					tool_call
				},
			}
			local resp = tools:call(session, tool_call)
			messages[#messages + 1] = resp
			ai:close()
			return llm_call(args)
		elseif delta.content then
			buf[#buf + 1] = delta.content
			local ok, err = session:write(delta.content)
			if not ok then
				return false, err
			end
		end
	end
end

return llm_call
