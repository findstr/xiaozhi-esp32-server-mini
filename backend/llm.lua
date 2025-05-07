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
---	session: session,
---	buf: string[],
---	openai: table,
---}
local function llm_call(args)
	local session = args.session
	local model_conf = conf.llm[args.model]
	if not model_conf then
		return false, "model not found: " .. args.model
	end
	local tools = args.tools
	local buf = args.buf
	local openai_args = args.openai
	if tools then
		openai_args.tools = tools:desc()
	end
	openai_args.stream = true
	local ai<close>, err = openai.open(model_conf, openai_args)
	if not ai then
		return false, err
	end
	local ch_out = session.ch_llm_output
	local messages = openai_args.messages
	while true do
		local obj
		obj, err = ai:readsse()
		if not obj then
			break
		end
		local delta = obj.choices[1].delta
		local tool_calls = delta.tool_calls
		if tool_calls then
			local call_args
			local tool_call = tool_calls[1]
			call_args, err = read_args(ai)
			if not call_args then
				break
			end
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
			local content = delta.content
			if #content > 0 then
				buf[#buf + 1] = content
				local ok = ch_out:push(content)
				logger.debugf("[llm] write `%s`, success:%s", content, ok)
				if not ok then -- 如果push失败，说明ch_out已经关闭，直接退出
					break
				end
			end
		end
	end
	return err == "EOF", err
end

return llm_call
