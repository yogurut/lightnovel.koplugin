local M = {}
M.__index = M
function M:new(o) o = o or {}; return setmetatable(o, M) end
return M
