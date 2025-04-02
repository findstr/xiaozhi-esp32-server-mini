local json = require "core.json"
local logger = require "core.logger"
local etcd = require "core.etcd"
local redis = require "core.db.redis"

local tools = require "tools"
local pb = require "pb"
local protoc = require "protoc"

local p = protoc:new()

local files = {
	"/home/zhoupy/work/zgame/protos/out/cl.proto",
	"/home/zhoupy/work/zgame/protos/in/db.proto",
	"/home/zhoupy/work/zgame/protos/in/config.proto",
}

for _, path in ipairs(files) do
	local f, err = io.open(path)
	if not f then
		logger.errorf("open file %s failed: %s", path, err)
		return
	end
	local filename = path:match("[^/]+$")
	local content = f:read("*a")
	f:close()
	assert(p:load(content, filename), filename)
end

local client = etcd.newclient {
	endpoints = { "172.16.16.16:2379" },
}

local function server_query(args)
	local list, err = client:get {
		key = "/game/zgame/logic/node",
		prefix = true
	}
	if not list then
		logger.error("[tools.servers] get etcd failed: %s", err)
		return {error = err}
	end
	local servers = {}
	for _, server in ipairs(list.kvs) do
		local v = server.value
		local obj = pb.decode("config.Logic", v)
		local x = {
			server_id = obj.server_id,
			redis = obj.redis,
			redis_index = obj.redis_index,
			server_name = obj.server_name,
		}
		servers[#servers + 1] = x
	end
	if args.server_name then
		for _, server in ipairs(servers) do
			if string.find(server.server_name, args.server_name) then
				return server
			end
		end
		return {error = "没有找到对应的服务器"}
	end
	return {error = "至少需要提供server_id或server_name"}
end

local function db_account(args)
	local server = server_query(args)
	if server.error then
		return server
	end
	print("server:", json.encode(server))
	local db = redis.new {
		addr = server.redis,
		db = server.redis_index,
		auth = "lovengame",
	}
	local ok, res = db:hlen("account")
	db:close()
	if ok then
		res = "数据库中共有" .. res .. "个玩家数据"
	end
	local buf = {
		success = ok,
		server = server,
		user_count = res,
	}
	return buf
end

local function db_user(args)
	local server = server_query(args)
	if server.error then
		return server
	end
	local db = redis.new {
		addr = server.redis,
		db = server.redis_index,
		auth = "lovengame",
	}
	local module = args.module
	local _, name = module:match("^([^.]+).([^.]+)$")
	name = name:gsub("Attr", "_")
	name = name:lower()
	local ok, res = db:hget("u:" .. args.uid, name)
	db:close()
	if ok then
		if res then
			res = res:sub(2)
			print("res length:", module, name, #res)
			local dat = pb.decode(module, res)
			res = "请将此玩家数据的json直接返回:" .. json.encode(dat)
			print("db_user", res)
		else
			res = "没有找到玩家数据"
		end
	end
	return {
		success = ok,
		server = server,
		user = res,
	}
end

local server_params = {
	type = "object",
	properties = {
		server_name = {
			type = "string",
			description = "服务器名称, 一般以xx服命名，如混沌服, QA服, 策划服等"
		},
	},
	required = {"server_name"}
}

local user_params = {
	type = "object",
	properties = {
		server_name = {
			type = "string",
			description = "服务器名称, 一般以xx服命名，如混沌服, QA服, 策划服等"
		},
		uid = {
			type = "string",
			description = "玩家uid"
		},
		module = {
			type = "string",
			description = "模块名称, 如db.ModuleAttr???"
		},
	},
	required = {"server_name", "uid", "module"}
}

tools.register {
	{
		exec = server_query,
		type = "function",
		["function"] = {
			name = "servers",
			description = "服务器配置信息查询, 如查询混沌服信息，查询混沌服的ip等",
			parameters = server_params,
		},
	},
	{
		type = "function",
		exec = db_account,
		["function"] = {
			name = "db_account",
			description = "查询数据库有多少玩家数据",
			parameters = server_params,
		},
	},
	{
		type = "function",
		exec = db_user,
		["function"] = {
			name = "db_user",
			description = "查询玩家模块数据, 如查询混沌服，uid为1234567890的ModuleFive的数据",
			parameters = user_params,
		},
	},
}
