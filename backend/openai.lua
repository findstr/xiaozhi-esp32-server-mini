local core = require "core"
local logger = require "core.logger"
local json = require "core.json"
local http = require "core.http"
local mutex = require "core.sync.mutex".new()

local tremove = table.remove
local concat = table.concat

---@class openai
---@field stream core.http.h1stream
---@field events string[]
---@field halfline string
local M = {}

local mt = {__index = M, __close = function(self)
	self:close()
end }

local alpn_protos = {"http/1.1", "h2"}
---@alias llm_name "chat" | "think" | "intent"

---@return core.http.h1stream|core.http.h2stream|nil, string|number|nil
local function open_stream(model_conf, req, txt)
	local stream, err = http.request("POST", model_conf.api_url, {
		["authorization"] = model_conf.api_key,
		["content-type"] = "application/json",
		["content-length"] = #txt,
	}, false, alpn_protos)
	if not stream then
		logger.errorf("[openai] open failed: %s", err)
		return nil, err
	end
	if stream.version == "HTTP/2" then
		stream:close(txt)
	else
		stream:write(txt)
	end
	local status, header = stream:readheader()
	if not status then
		logger.errorf("[openai] read header failed: %s", header)
		return nil, header
	end
	return stream, status
end

---@param req {
---	llm: llm_name,
---	messages: table[],
---	tools: table[]?,
---	temperature: number?,
---	model: string?,
---}
---@return openai?, string? error
function M.open(model_conf, req)
	local lock = mutex:lock(model_conf.api_url)
	req.model = model_conf.model
	local txt = json.encode(req)
	local stream, status
	--logger.debugf("[openai] request: %s", txt)
	for i = 1, 2 do
		stream, status = open_stream(model_conf, req, txt)
		if stream then
			break
		end
		logger.errorf("[openai] open failed: %s", status)
		core.sleep(100)
	end
	if not stream then
		lock:unlock()
		return nil, "open failed"
	end
	if status ~= 200 then
		lock:unlock()
		return nil, "status: " .. status
	end
	return setmetatable({
		lock = lock,
		stream = stream,
		halfline = "",
		events = {},
	}, mt), nil
end

local function read_event(self)
	local events = self.events
	local line, err = self.stream:read()
	if not line then
		logger.errorf("[openai] read_event failed: %s", err)
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
	--logger.debugf("[openai] readsse: %s", event)
	local obj = json.decode(event)
	assert(obj, "decode failed: " .. event)
	return obj, nil
end

function M:close()
	if self.lock then
		self.lock:unlock()
		self.lock = nil
	end
	self.stream:close()
end

return M
