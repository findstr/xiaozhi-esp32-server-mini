local require = require
local t = setmetatable({}, {__index = function(t, k)
	local v = require ("agent." .. k)
	if v then
		t[k] = v
		return v
	end
end})


return t