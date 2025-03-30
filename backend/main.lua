local dns = require "core.dns"
local conf = require "conf"
dns.server("8.8.8.8:53")
local ip = dns.lookup(conf.vector_db.redis.addr, dns.A)
print(ip)
conf.vector_db.redis.addr = ip

local memory = require "memory"
memory.start()

require "server.web"
require "server.xiaozhi"
