local core = require "core"
local logger = require "core.logger"
local time = require "core.time"
local json = require "core.json"
local http = require "core.http"
local conf = require "conf"

local tremove = table.remove
local concat = table.concat

---@class openai
---@field stream core.http.h1stream
---@field events string[]
---@field halfline string
---@field header boolean
local M = {}

local mt = {__index = M, __close = function(self)
	self:close()
end }

local alpn_protos = {"http/1.1", "h2"}
---@alias llm_name "chat" | "think" | "intent"

---@param req {
---	llm: llm_name,
---	stream: boolean,
---	messages: table[],
---	tools: table[]?,
---	temperature: number?,
---	model: string?,
---}
---@return openai?, string? error
function M.open(req)
	local model_conf = conf.llm[req.llm]
	if not model_conf then
		error("model not found: " .. req.llm)
	end
	req.llm = nil
	req.model = model_conf.model
	local txt = json.encode(req)
	local stream, err = http.request("POST", model_conf.api_url, {
		["authorization"] = model_conf.api_key,
		["content-type"] = "application/json",
		["content-length"] = #txt,
	}, false, alpn_protos)
	if not stream then
		logger.error("openai open failed: %s", err)
		return nil, err
	end
	if stream.version == "HTTP/2" then
		stream:close(txt)
	else
		stream:write(txt)
	end
	return setmetatable({
		stream = stream,
		halfline = "",
		header = false,
		events = {},
	}, mt), nil
end

local function read_event(self)
	local events = self.events
	local line, err = self.stream:read()
	if not line then
		return nil, err
	end
	line = self.halfline .. line
	self.halfline = ""
	local i = 1
	while true do
		local s, e = line:find("\n\n", i, true)
		if s then
			local str = line:match("^%s*data:%s*([^\r\n]+)", i)
			events[#events + 1] = str
			i = e + 1
		else
			self.halfline = line:sub(i)
			break
		end
	end
end

function M:read()
	local status, header = self.stream:readheader()
	if not status then
		print("read header failed:", header)
		return nil, header
	end
	if status ~= 200 then
		return nil, "status: " .. self.stream:read()
	end
	local buf = {}
	while true do
		local line, err = self.stream:read()
		if not line or #line == 0 then
			break
		end
		buf[#buf + 1] = line
	end
	local line = concat(buf)
	local obj = json.decode(line)
	assert(obj, "decode failed: " .. line)
	return obj, nil
end

function M:readsse()
	if not self.header then
		local status, header = self.stream:readheader()
		if not status then
			return nil, header
		end
		if status ~= 200 then
			return nil, "status: " .. self.stream:read()
		end
		self.header = true
	end
	if not self.events then
		return nil, "EOF"
	end
	local events = self.events
	if #events == 0 then
		read_event(self)
	end
	local event = tremove(events, 1)
	if not event or event == "[DONE]" then
		self.events = nil
		return nil, "EOF"
	end
	local obj = json.decode(event)
	assert(obj, "decode failed: " .. event)
	return obj, nil
end

function M:close()
	self.stream:close()
end

return M
