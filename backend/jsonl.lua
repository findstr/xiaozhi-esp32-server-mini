local json = require "core.json"

local M = {}

function M.load(filename)
	local f<close> = io.open(filename, "r")
	local data = {}
	for line in f:lines() do
		data[#data + 1] = json.decode(line)
	end
	return data
end

return M
