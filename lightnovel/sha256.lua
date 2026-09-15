--[[
轻书架 KOReader 插件 —— SHA-256（纯 Lua 实现，回退用）

仅当设备缺少 ffi/sha2 时使用。实现依据 FIPS 180-4。
]]

local M = {}

local bit = require("bit")

local floor = math.floor
local char, byte, sub = string.char, string.byte, string.sub
local concat, rep = table.concat, string.rep
local band, bor, bxor, rshift, lshift, bnot = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift, bit.bnot
local tobit = bit.tobit or function(x) return x end

-- 逻辑右移（Lua 5.1 bit 库无 >>>）
local function rrot(x, n)
    n = n % 32
    if n == 0 then return tobit(x) end
    return tobit(bor(rshift(x, n), lshift(x, 32 - n)))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function preprocess(msg)
    local len = #msg
    local bitlen = len * 8
    msg = msg .. "\128"
    local pad = (56 - (len + 1) % 64) % 64
    msg = msg .. rep("\0", pad)
    -- 64 位大端长度（高 32 位一般可忽略）
    local hi = floor(bitlen / 4294967296)
    local lo = bitlen % 4294967296
    msg = msg .. char(
        band(rshift(hi, 24), 0xff), band(rshift(hi, 16), 0xff), band(rshift(hi, 8), 0xff), band(hi, 0xff),
        band(rshift(lo, 24), 0xff), band(rshift(lo, 16), 0xff), band(rshift(lo, 8), 0xff), band(lo, 0xff))
    return msg
end

local function hex32(n)
    -- LuaJIT/Lua 5.1 的 string.format("%x") 对负数无效，逐字节转换兼容性最好
    return string.format("%02x%02x%02x%02x",
        band(rshift(n, 24), 0xff),
        band(rshift(n, 16), 0xff),
        band(rshift(n, 8), 0xff),
        band(n, 0xff))
end

function M.hex(message)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local msg = preprocess(message)
    local w = {}

    for chunk_start = 1, #msg, 64 do
        for i = 0, 15 do
            local o = chunk_start + i * 4
            w[i] = bor(
                lshift(byte(msg, o), 24),
                lshift(byte(msg, o + 1), 16),
                lshift(byte(msg, o + 2), 8),
                byte(msg, o + 3))
            w[i] = tobit(w[i])
        end
        for i = 16, 63 do
            local s0 = bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18), rshift(w[i - 15], 3))
            local s1 = bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19), rshift(w[i - 2], 10))
            w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7

        for i = 0, 63 do
            local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = tobit(h + S1 + ch + K[i + 1] + w[i])
            local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = tobit(S0 + maj)

            h = g; g = f; f = e
            e = tobit(d + temp1)
            d = c; c = b; b = a
            a = tobit(temp1 + temp2)
        end

        h0 = tobit(h0 + a); h1 = tobit(h1 + b); h2 = tobit(h2 + c); h3 = tobit(h3 + d)
        h4 = tobit(h4 + e); h5 = tobit(h5 + f); h6 = tobit(h6 + g); h7 = tobit(h7 + h)
    end

    return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3)
        .. hex32(h4) .. hex32(h5) .. hex32(h6) .. hex32(h7)
end

return M
