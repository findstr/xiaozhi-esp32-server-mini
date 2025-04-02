local http = require "core.http"
local json = require "core.json"
local logger = require "core.logger"
local base64 = require "core.base64"
local conf = require "conf"

local api_url = conf.embedding.openai.api_url
local en_model = conf.embedding.openai.en_model
local cn_model = conf.embedding.openai.cn_model
local key = conf.embedding.openai.api_key

local type = type

---@param txt string|string[]
---@return number[][]?, string? error
local function embedding(txt)
	local t = type(txt)
	assert(t == "string" or t == "table", t)
	local single = t == "string"
	local res, err = http.POST(api_url, {
		["authorization"] = key,
		["content-type"] = "application/json",
	}, json.encode({
		model = cn_model,
		input = txt,
		encoding_format = "base64",
	}))
	if not res then
		return nil, err
	end
	local result = json.decode(res.body)
	if not result then
		logger.errorf("[embedding.openai] failed to decode result: %s", res.body)
		return nil, "failed to decode result"
	end
	if single then
		return base64.decode(result.data[1].embedding), nil
	end
	local vectors = {}
	for _, v in ipairs(result.data) do
		vectors[v.index+1] = base64.decode(v.embedding)
	end
	return vectors, nil
end

return embedding