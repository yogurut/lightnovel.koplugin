--[[
轻书架 KOReader 插件 —— MessagePack 编解码（纯 Lua 实现）

用于与 SignalR Hub 通信。轻书架 Hub 使用 MessagePack 二进制协议，
需要在 Lua 侧实现最小可用的 MessagePack 编解码器。

支持类型：
  - nil / boolean / number(int,float) / string / array / map
  - 轻书架实际使用到的所有类型均在此覆盖
]]

local bit = require("bit")
local Log = require("lightnovel.logger")

local M = {}

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local char, byte, sub, rep = string.char, string.byte, string.sub, string.rep
local floor, abs = math.floor, math.abs
local huge = math.huge

-- ============ 编码 ============

local function encode_uint(out, n)
    if n < 0x80 then
        out[#out + 1] = char(n)
    elseif n <= 0xff then
        out[#out + 1] = char(0xcc, n)
    elseif n <= 0xffff then
        out[#out + 1] = char(0xcd, band(rshift(n, 8), 0xff), band(n, 0xff))
    elseif n <= 0xffffffff then
        out[#out + 1] = char(0xce,
            band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
            band(rshift(n, 8), 0xff), band(n, 0xff))
    else
        -- uint64：Lua 5.1 number 为 double，仅支持 53 位精度
        out[#out + 1] = char(0xcf, 0, 0, 0, 0,
            band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
            band(rshift(n, 8), 0xff), band(n, 0xff))
    end
end

local function encode_int(out, n)
    if n >= 0 then
        encode_uint(out, n)
    elseif n >= -32 then
        out[#out + 1] = char(0xe0 + (n + 32))
    elseif n >= -128 then
        out[#out + 1] = char(0xd0, band(n, 0xff))
    elseif n >= -32768 then
        out[#out + 1] = char(0xd1, band(rshift(n, 8), 0xff), band(n, 0xff))
    elseif n >= -2147483648 then
        out[#out + 1] = char(0xd2,
            band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
            band(rshift(n, 8), 0xff), band(n, 0xff))
    else
        out[#out + 1] = char(0xd3, 0xff, 0xff, 0xff, 0xff,
            band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
            band(rshift(n, 8), 0xff), band(n, 0xff))
    end
end

local function encode_float(out, n)
    -- IEEE 754 double，小端序
    out[#out + 1] = char(0xcb)
    local sign = 0
    if n < 0 or (n == 0 and 1 / n < 0) then
        sign = 0x80
        n = -n
    end
    if n ~= n then
        out[#out + 1] = char(0, 0, 0, 0, 0, 0, 0xf8, 0x7f)
        return
    elseif n == huge then
        out[#out + 1] = char(0, 0, 0, 0, 0, 0, 0xf0, bor(0x7f, sign))
        return
    end
    local mant, expo = math.frexp(n)
    if mant == 0 then
        out[#out + 1] = char(0, 0, 0, 0, 0, 0, 0, 0)
        return
    end
    expo = expo + 1022
    mant = floor((mant * 2 - 1) * 2 ^ 52 + 0.5)
    local b = {}
    for i = 1, 6 do
        b[i] = band(mant, 0xff)
        mant = floor(mant / 256)
    end
    b[7] = bor(band(expo, 0x0f) * 16, band(mant, 0x0f))
    b[8] = bor(band(floor(expo / 16), 0x7f), sign)
    out[#out + 1] = char(b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
end

local function encode_string(out, s)
    local n = #s
    if n < 32 then
        out[#out + 1] = char(0xa0 + n)
    elseif n <= 0xff then
        out[#out + 1] = char(0xd9, n)
    elseif n <= 0xffff then
        out[#out + 1] = char(0xda, band(rshift(n, 8), 0xff), band(n, 0xff))
    else
        out[#out + 1] = char(0xdb,
            band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
            band(rshift(n, 8), 0xff), band(n, 0xff))
    end
    out[#out + 1] = s
end

local function encode_array(out, t)
    local n = #t
    if n < 16 then
        out[#out + 1] = char(0x90 + n)
    elseif n <= 0xffff then
        out[#out + 1] = char(0xdc, band(rshift(n, 8), 0xff), band(n, 0xff))
    else
        out[#out + 1] = char(0xdd,
            band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
            band(rshift(n, 8), 0xff), band(n, 0xff))
    end
end

local function encode_map(out, t, count)
    local n = count
    if n < 16 then
        out[#out + 1] = char(0x80 + n)
    elseif n <= 0xffff then
        out[#out + 1] = char(0xde, band(rshift(n, 8), 0xff), band(n, 0xff))
    else
        out[#out + 1] = char(0xdf,
            band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
            band(rshift(n, 8), 0xff), band(n, 0xff))
    end
end

local encode_value

-- 显式标记：空表或期望编码为 map 的表
-- 用法：mp.as_map({}) 或 mp.as_map({a=1})
local MAP_MARKER = {}

function M.as_map(t)
    t = t or {}
    t[MAP_MARKER] = true
    return t
end

-- 判断 table 是数组还是 map
local function table_kind(t)
    if t[MAP_MARKER] then
        local count = 0
        for k, _ in pairs(t) do
            if k ~= MAP_MARKER then count = count + 1 end
        end
        return "map", count
    end

    local count = 0
    local max_n = 0
    for k, _ in pairs(t) do
        count = count + 1
        if type(k) == "number" and k > 0 and k == floor(k) then
            if k > max_n then max_n = k end
        else
            return "map", count
        end
    end
    if count == 0 then return "array", 0 end     -- 空表默认按数组处理
    if max_n == count then return "array", count end
    return "map", count
end

encode_value = function(out, v)
    local tv = type(v)
    if v == nil then
        out[#out + 1] = char(0xc0)
    elseif tv == "boolean" then
        out[#out + 1] = char(v and 0xc3 or 0xc2)
    elseif tv == "number" then
        if v == floor(v) and abs(v) < 2 ^ 53 then
            encode_int(out, v)
        else
            encode_float(out, v)
        end
    elseif tv == "string" then
        encode_string(out, v)
    elseif tv == "table" then
        local kind, count = table_kind(v)
        if kind == "array" then
            encode_array(out, v)
            for i = 1, count do
                encode_value(out, v[i])
            end
        else
            encode_map(out, v, count)
            for k, val in pairs(v) do
                if k ~= MAP_MARKER then
                    encode_value(out, k)
                    encode_value(out, val)
                end
            end
        end
    else
        Log.warn("MessagePack 不支持的类型: %s", tv)
        out[#out + 1] = char(0xc0)
    end
end

function M.encode(v)
    local out = {}
    encode_value(out, v)
    return table.concat(out)
end

-- ============ 解码 ============

local function decode_float_le(s, pos, size)
    local b = {}
    for i = 0, size - 1 do
        b[i] = byte(s, pos + i)
    end
    if size == 4 then
        -- float32
        local sign = (b[3] >= 128) and -1 or 1
        local expo = band(rshift(b[3], 7), 0xff) * 2 + band(rshift(b[2], 7), 1)
        local mant = band(b[2], 0x7f) * 65536 + b[1] * 256 + b[0]
        if expo == 0 then
            return sign * mant * 2 ^ (-149), pos + 4
        elseif expo == 255 then
            return sign * (mant == 0 and huge or (0 / 0)), pos + 4
        end
        return sign * (1 + mant / 2 ^ 23) * 2 ^ (expo - 127), pos + 4
    end
    -- float64
    local sign = (b[7] >= 128) and -1 or 1
    local expo = band(rshift(b[7], 4), 0x7f) * 16 + band(rshift(b[6], 4), 0x0f)
    local mant = band(b[6], 0x0f) * 2 ^ 48
    mant = mant + b[5] * 2 ^ 40 + b[4] * 2 ^ 32 + b[3] * 2 ^ 24
        + b[2] * 65536 + b[1] * 256 + b[0]
    if expo == 0 then
        return sign * mant * 2 ^ (-1074), pos + 8
    elseif expo == 2047 then
        return sign * (mant == 0 and huge or (0 / 0)), pos + 8
    end
    return sign * (1 + mant / 2 ^ 52) * 2 ^ (expo - 1023), pos + 8
end

local decode_value

local function decode_str(s, pos, len)
    return sub(s, pos, pos + len - 1), pos + len
end

local function decode_array(s, pos, len)
    local t = {}
    for i = 1, len do
        local v
        v, pos = decode_value(s, pos)
        t[i] = v
    end
    return t, pos
end

local function decode_map(s, pos, len)
    local t = {}
    for _ = 1, len do
        local k, v
        k, pos = decode_value(s, pos)
        v, pos = decode_value(s, pos)
        -- MessagePack 的 key 可能是任意类型；Lua table 只接受 string/number/bool
        if type(k) ~= "string" and type(k) ~= "number" then k = tostring(k) end
        t[k] = v
    end
    return t, pos
end

decode_value = function(s, pos)
    local b = byte(s, pos)
    if not b then return nil, pos end
    pos = pos + 1

    -- positive fixint
    if b < 0x80 then return b, pos end
    -- negative fixint
    if b >= 0xe0 then return b - 256, pos end
    -- fixmap
    if b >= 0x80 and b <= 0x8f then return decode_map(s, pos, b - 0x80) end
    -- fixarray
    if b >= 0x90 and b <= 0x9f then return decode_array(s, pos, b - 0x90) end
    -- fixstr
    if b >= 0xa0 and b <= 0xbf then return decode_str(s, pos, b - 0xa0) end

    if b == 0xc0 then return nil, pos end
    if b == 0xc2 then return false, pos end
    if b == 0xc3 then return true, pos end

    if b == 0xc4 then
        local len = byte(s, pos); return decode_str(s, pos + 1, len)
    elseif b == 0xc5 then
        local len = byte(s, pos) * 256 + byte(s, pos + 1)
        return decode_str(s, pos + 2, len)
    elseif b == 0xc6 then
        local len = byte(s, pos) * 65536 + byte(s, pos + 1) * 256 + byte(s, pos + 2)
        return decode_str(s, pos + 3, len)
    elseif b == 0xca then
        return decode_float_le(s, pos, 4)
    elseif b == 0xcb then
        return decode_float_le(s, pos, 8)
    elseif b == 0xcc then
        return byte(s, pos), pos + 1
    elseif b == 0xcd then
        return byte(s, pos) * 256 + byte(s, pos + 1), pos + 2
    elseif b == 0xce then
        return byte(s, pos) * 16777216 + byte(s, pos + 1) * 65536
            + byte(s, pos + 2) * 256 + byte(s, pos + 3), pos + 4
    elseif b == 0xcf then
        -- uint64
        local hi = byte(s, pos) * 16777216 + byte(s, pos + 1) * 65536
            + byte(s, pos + 2) * 256 + byte(s, pos + 3)
        local lo = byte(s, pos + 4) * 16777216 + byte(s, pos + 5) * 65536
            + byte(s, pos + 6) * 256 + byte(s, pos + 7)
        return hi * 4294967296 + lo, pos + 8
    elseif b == 0xd0 then
        local n = byte(s, pos); if n >= 128 then n = n - 256 end
        return n, pos + 1
    elseif b == 0xd1 then
        local n = byte(s, pos) * 256 + byte(s, pos + 1)
        if n >= 32768 then n = n - 65536 end
        return n, pos + 2
    elseif b == 0xd2 then
        local n = byte(s, pos) * 16777216 + byte(s, pos + 1) * 65536
            + byte(s, pos + 2) * 256 + byte(s, pos + 3)
        if n >= 2147483648 then n = n - 4294967296 end
        return n, pos + 4
    elseif b == 0xd3 then
        local hi = byte(s, pos) * 16777216 + byte(s, pos + 1) * 65536
            + byte(s, pos + 2) * 256 + byte(s, pos + 3)
        local lo = byte(s, pos + 4) * 16777216 + byte(s, pos + 5) * 65536
            + byte(s, pos + 6) * 256 + byte(s, pos + 7)
        local n = hi * 4294967296 + lo
        if n >= 9223372036854775808 then n = n - 18446744073709551616 end
        return n, pos + 8
    elseif b == 0xd9 then
        local len = byte(s, pos); return decode_str(s, pos + 1, len)
    elseif b == 0xda then
        local len = byte(s, pos) * 256 + byte(s, pos + 1)
        return decode_str(s, pos + 2, len)
    elseif b == 0xdb then
        local len = byte(s, pos) * 65536 + byte(s, pos + 1) * 256 + byte(s, pos + 2)
        return decode_str(s, pos + 3, len)
    elseif b == 0xdc then
        local len = byte(s, pos) * 256 + byte(s, pos + 1)
        return decode_array(s, pos + 2, len)
    elseif b == 0xdd then
        local len = byte(s, pos) * 16777216 + byte(s, pos + 1) * 65536
            + byte(s, pos + 2) * 256 + byte(s, pos + 3)
        return decode_array(s, pos + 4, len)
    elseif b == 0xde then
        local len = byte(s, pos) * 256 + byte(s, pos + 1)
        return decode_map(s, pos + 2, len)
    elseif b == 0xdf then
        local len = byte(s, pos) * 16777216 + byte(s, pos + 1) * 65536
            + byte(s, pos + 2) * 256 + byte(s, pos + 3)
        return decode_map(s, pos + 4, len)
    end

    Log.warn("MessagePack 未知类型标记: 0x%02x @ %d", b, pos - 1)
    return nil, pos
end

function M.decode(s, pos)
    return decode_value(s, pos or 1)
end

-- 解码多个连续对象
function M.decode_all(s)
    local out = {}
    local pos = 1
    while pos <= #s do
        local v
        v, pos = decode_value(s, pos)
        if v == nil and pos > #s then break end
        out[#out + 1] = v
    end
    return out
end

return M
