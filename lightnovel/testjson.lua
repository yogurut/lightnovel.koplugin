-- 最小 JSON 实现，仅用于本地验证（KOReader 真机上是 C 版 rapidjson）
-- 仅用于本地测试（KOReader 真机使用 C 版 rapidjson）。
-- 放在 lightnovel/ 下是为了让 test/ 能 require 到。

local M = {}
local function esc(s)
    return (s:gsub('[%z\1-\31\\"]', function(c)
        local map = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b',
                      ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
        return map[c] or string.format('\\u%04x', c:byte())
    end))
end
function M.encode(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return tostring(v)
    elseif t == "string" then return '"' .. esc(v) .. '"'
    elseif t == "table" then
        local isarr, n = true, 0
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" then isarr = false end
        end
        if n == 0 then return "{}" end
        if isarr then
            local p = {}
            for i = 1, n do p[i] = M.encode(v[i]) end
            return "[" .. table.concat(p, ",") .. "]"
        end
        local p = {}
        for k, val in pairs(v) do p[#p+1] = M.encode(tostring(k)) .. ":" .. M.encode(val) end
        return "{" .. table.concat(p, ",") .. "}"
    end
    return "null"
end

-- 极简解码：够解析本接口的响应即可
local function skip_ws(s, i) while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end return i end
local parse_value
local function parse_string(s, i)
    i = i + 1
    local buf = {}
    while i <= #s do
        local c = s:sub(i,i)
        if c == '"' then return table.concat(buf), i + 1 end
        if c == "\\" then
            local n = s:sub(i+1,i+1)
            local map = { n='\n', t='\t', r='\r', b='\b', f='\f', ['"']='"', ['\\']='\\', ['/']='/' }
            if map[n] then buf[#buf+1] = map[n]; i = i + 2
            elseif n == "u" then
                local h = s:sub(i+2, i+5)
                buf[#buf+1] = string.char(tonumber(h, 16) % 256)
                i = i + 6
            else buf[#buf+1] = n; i = i + 2 end
        else buf[#buf+1] = c; i = i + 1 end
    end
    return table.concat(buf), i
end
parse_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i,i)
    if c == "{" then
        local o = {}; i = skip_ws(s, i+1)
        if s:sub(i,i) == "}" then return o, i+1 end
        while true do
            local k; k, i = parse_string(s, skip_ws(s, i))
            i = skip_ws(s, i); i = i + 1 -- :
            local v; v, i = parse_value(s, skip_ws(s, i))
            o[k] = v; i = skip_ws(s, i)
            local ch = s:sub(i,i)
            if ch == "," then i = i + 1 else return o, i + 1 end
        end
    elseif c == "[" then
        local a = {}; i = skip_ws(s, i+1)
        if s:sub(i,i) == "]" then return a, i+1 end
        while true do
            local v; v, i = parse_value(s, skip_ws(s, i))
            a[#a+1] = v; i = skip_ws(s, i)
            local ch = s:sub(i,i)
            if ch == "," then i = i + 1 else return a, i + 1 end
        end
    elseif c == '"' then return parse_string(s, i)
    elseif s:sub(i, i+3) == "true" then return true, i+4
    elseif s:sub(i, i+4) == "false" then return false, i+5
    elseif s:sub(i, i+3) == "null" then return nil, i+4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        return tonumber(num), i + #num
    end
end
function M.decode(s)
    local ok, v = pcall(parse_value, s, 1)
    if not ok then return nil end
    return v
end
return M
