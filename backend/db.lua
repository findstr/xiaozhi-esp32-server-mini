local redis = require "core.db.redis"
local conf = require "conf"

local addr = string.format("%s:%s", conf.vector_db.redis.addr, conf.vector_db.redis.port)
print("addr:", addr)
local db, err = redis.new {
	addr = addr,
	auth = conf.vector_db.redis.auth,
	db = 0,
}
assert(db, err)

return db
