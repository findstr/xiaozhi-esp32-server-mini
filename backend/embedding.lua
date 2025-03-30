local conf = require "conf"
local embedding = require ("embedding." .. conf.embedding.use)

return embedding
