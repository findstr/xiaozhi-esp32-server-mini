local conf = require "conf"
local asr = require ("asr." .. conf.asr.use)

return asr
