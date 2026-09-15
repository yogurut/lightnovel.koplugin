local M = {}
M.__index = M
function M:new(n, a) return setmetatable({name=n,args=a}, M) end
return M
