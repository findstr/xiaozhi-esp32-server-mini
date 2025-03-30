local grpc = require "core.grpc"
local protoc = require "protoc"
local conf = require "conf"

local p = protoc:new()


local f<close>, err = io.open("proto/vad.proto")
assert(f, err)
local data = f:read("a")
local ok = p:load(data, "vad.proto")
assert(ok)

local proto = p.loaded["vad.proto"]
local client, err = grpc.newclient {
	service = "SileroVad",
	endpoints = {conf.vad.grpc_addr},
	proto = proto,
	timeout = 5000,
}
assert(client, err)



---@return core.grpc.stream?, string? error
local function vad()
	local stream, err = client.Feed()
	return stream, err
end

return vad