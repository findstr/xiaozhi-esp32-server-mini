local json = require "core.json"
local logger = require "core.logger"

local ipairs = ipairs

local desc_list = {}
local fns = {}

local M = {}

function M.desc()
	return desc_list
end

function M.register(descs)
	for _, desc in ipairs(descs) do
		desc_list[#desc_list + 1] = desc
		fns[desc['function'].name] = desc.exec
		desc.exec = nil
	end
end

---@param session xiaozhi.session
function M.call(session, call)
	logger.debugf("call: %s", json.encode(call))
	local id = call.id
	local fn = call['function']
	local f = fns[fn.name]
	local content = ""
	if f then
		local res = f(session, json.decode(fn.arguments))
		content = json.encode(res)
	end
	return {
		role = "tool",
		tool_call_id = id,
		content = content,
	}
end

return M
