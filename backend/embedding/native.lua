local grpc = require "core.grpc"
local logger = require "core.logger"
local protoc = require "protoc"
local conf = require "conf"

local p = protoc:new()
local type = type

local f<close>, err = io.open("proto/embedding.proto")
assert(f, err)
local data = f:read("a")
local ok = p:load(data, "embedding.proto")
assert(ok)

local proto = p.loaded["embedding.proto"]

local client, err = grpc.newclient {
	service = "Embedding",
	endpoints = {conf.embedding.native.grpc_addr},
	proto = proto,
	timeout = 500000000,
}
assert(client, err)

---@param txt string|string[]
---@return number[][]?, string? error
local function embedding(txt)
	local single = type(txt) == "string"
	local docs = {}
	if single then
		docs[1] = {
			text = txt,
		}
	else
		for i, v in ipairs(txt) do
			docs[i] = {
				text = v,
			}
		end
	end
	local res, err = client:Encode(docs)
	if not res then
		logger.errorf("[embedding.native] embedding failed: %s", err)
		return nil, err
	end
	if single then
		return res.results[1].vector, nil
	end
	local vectors = {}
	for _, v in ipairs(res.results) do
		vectors[v.id] = v.vector
	end
	return vectors, nil
end

return embedding