local json = require "core.json"
local logger = require "core.logger"

local setmetatable = setmetatable
local ipairs = ipairs

---@class tools_mt
local M = {}
local mt = {__index = M}

function M.new()
	---@class tools : tools_mt
	local o = setmetatable({
		desc_list = {},
		fns = {},
	}, mt)
	return o
end


function M:desc()
	return self.desc_list
end

function M:register(tools)
	local desc_list = self.desc_list
	local fns = self.fns
	for _, tool in ipairs(tools) do
		desc_list[#desc_list + 1] = tool.desc
		fns[tool.desc['function'].name] = tool.exec
	end
end

---@param self tools
---@param session xiaozhi.session
function M:call(session, call)
	logger.debugf("call: %s", json.encode(call))
	local id = call.id
	local fn = call['function']
	local f = self.fns[fn.name]
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
