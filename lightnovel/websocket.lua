--[[
轻书架 KOReader 插件 —— WebSocket 客户端（纯 Lua 实现）

KOReader 未内置 WebSocket 客户端，这里基于 LuaSocket + LuaSec 实现 RFC 6455 的最小客户端。

支持：
  - ws:// 与 wss://（TLS 通过 LuaSec）
  - 客户端 masking（RFC 6455 要求客户端必须掩码）
  - 文本帧 / 二进制帧 发送与接收
  - 分片与 ping/pong（最小处理）
]]

local socket = require("socket")
local ssl = require("ssl")
local bit = require("bit")
local Log = require("lightnovel.logger")

local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local M = {}

local WS = {}
WS.__index = WS

local OPCODE = {
    CONTINUATION = 0x0,
    TEXT = 0x1,
    BINARY = 0x2,
    CLOSE = 0x8,
    PING = 0x9,
    PONG = 0xA,
}

-- ============ 底层收发 ============

local function make_send(sock, is_ssl)
    return function(data)
        local ok, err = sock:send(data)
        return ok, err
    end
end

-- 精确读取 n 字节
local function recv_exact(sock, n, timeout)
    local chunks = {}
    local got = 0
    while got < n do
        sock:settimeout(timeout or 10)
        local data, err, partial = sock:receive(n - got)
        if data then
            chunks[#chunks + 1] = data
            got = got + #data
        elseif partial and #partial > 0 then
            chunks[#chunks + 1] = partial
            got = got + #partial
        else
            if err == "timeout" or err == "closed" then
                return nil, err
            end
            return nil, err or "接收失败"
        end
    end
    return table.concat(chunks)
end

-- ============ 握手 ============

local function base64_encode(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local out = {}
    local n = #data
    for i = 1, n, 3 do
        local b1 = data:byte(i) or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local c1 = rshift(b1, 2)
        local c2 = bor(lshift(band(b1, 3), 4), rshift(b2, 4))
        local c3 = bor(lshift(band(b2, 15), 2), rshift(b3, 6))
        local c4 = band(b3, 63)
        out[#out + 1] = b:sub(c1 + 1, c1 + 1)
        out[#out + 1] = b:sub(c2 + 1, c2 + 1)
        if i + 1 <= n then out[#out + 1] = b:sub(c3 + 1, c3 + 1) else out[#out + 1] = "=" end
        if i + 2 <= n then out[#out + 1] = b:sub(c4 + 1, c4 + 1) else out[#out + 1] = "=" end
    end
    return table.concat(out)
end

local function parse_ws_url(url)
    local scheme, rest
    if url:match("^wss://") then
        scheme = "tls"; rest = url:sub(7)
    elseif url:match("^ws://") then
        scheme = "tcp"; rest = url:sub(6)
    else
        return nil, "URL 必须以 ws:// 或 wss:// 开头"
    end

    local host_port, path = rest:match("^([^/]+)(/.*)$")
    if not host_port then host_port = rest; path = "/" end

    local host, port = host_port:match("^([^:]+):(%d+)$")
    if not host then
        host = host_port
        port = (scheme == "tls") and 443 or 80
    end

    return {
        scheme = scheme,
        host = host,
        port = tonumber(port),
        path = path or "/",
    }
end

-- 建立 WebSocket 连接
-- url: ws:// 或 wss:// 地址（可含 query）
-- opts.headers: 额外请求头
function M.connect(url, opts)
    opts = opts or {}
    local info, err = parse_ws_url(url)
    if not info then return nil, err end

    -- TCP 连接
    local sock = socket.tcp()
    if not sock then return nil, "无法创建 socket" end
    sock:settimeout(opts.timeout or 20)

    local ok, cerr = sock:connect(info.host, info.port)
    if not ok then
        sock:close()
        return nil, "TCP 连接失败: " .. tostring(cerr)
    end

    -- TLS 包装
    if info.scheme == "tls" then
        local params = {
            mode = "client",
            protocol = "tlsv1_2",
            verify = "none",   -- 墨水屏设备证书库不完整，跳过校验
            options = "all",
        }
        local wrapped, werr = ssl.wrap(sock, params)
        if not wrapped then
            sock:close()
            return nil, "TLS 包装失败: " .. tostring(werr)
        end
        sock = wrapped
        local hok, herr = sock:dohandshake()
        if not hok then
            sock:close()
            return nil, "TLS 握手失败: " .. tostring(herr)
        end
    end

    -- 生成随机 Sec-WebSocket-Key
    local key_bytes = {}
    for i = 1, 16 do
        key_bytes[i] = string.char(math.random(0, 255))
    end
    local ws_key = base64_encode(table.concat(key_bytes))

    -- 构造握手请求
    local lines = {
        "GET " .. info.path .. " HTTP/1.1",
        "Host: " .. info.host .. (info.port ~= 80 and info.port ~= 443 and (":" .. info.port) or ""),
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. ws_key,
        "Sec-WebSocket-Version: 13",
        "User-Agent: KOReader/lightnovel.koplugin",
    }
    if opts.headers then
        for k, v in pairs(opts.headers) do
            lines[#lines + 1] = k .. ": " .. tostring(v)
        end
    end

    local req = table.concat(lines, "\r\n") .. "\r\n\r\n"
    local sok, serr = sock:send(req)
    if not sok then
        sock:close()
        return nil, "握手请求发送失败: " .. tostring(serr)
    end

    -- 读取握手响应（直到 \r\n\r\n）
    local resp = {}
    local total = ""
    while not total:find("\r\n\r\n", 1, true) do
        sock:settimeout(15)
        local data, rerr, partial = sock:receive(1024)
        if data then
            total = total .. data
        elseif partial and #partial > 0 then
            total = total .. partial
        else
            sock:close()
            return nil, "握手响应读取失败: " .. tostring(rerr)
        end
        if #total > 16384 then
            sock:close()
            return nil, "握手响应过大"
        end
    end

    if not total:match("^HTTP/1%.1 101") then
        sock:close()
        local status = total:match("^HTTP/1%.1 (%d+)") or "?"
        return nil, "WebSocket 握手被拒绝 (HTTP " .. status .. ")"
    end

    Log.info("WebSocket 已连接 %s:%d", info.host, info.port)

    return setmetatable({
        sock = sock,
        host = info.host,
        path = info.path,
    }, WS)
end

-- ============ 帧收发 ============

-- 发送帧
function WS:_send_frame(opcode, payload)
    local fin_and_opcode = bor(0x80, opcode)  -- FIN=1
    local mask_bit = 0x80
    local len = #payload
    local header

    if len < 126 then
        header = string.char(fin_and_opcode, bor(mask_bit, len))
    elseif len < 65536 then
        header = string.char(fin_and_opcode, bor(mask_bit, 126),
            band(rshift(len, 8), 0xff), band(len, 0xff))
    else
        header = string.char(fin_and_opcode, bor(mask_bit, 127), 0, 0, 0, 0,
            band(rshift(len, 24), 0xff), band(rshift(len, 16), 0xff),
            band(rshift(len, 8), 0xff), band(len, 0xff))
    end

    -- 掩码
    local mask = {}
    for i = 1, 4 do mask[i] = math.random(0, 255) end
    local mask_str = string.char(mask[1], mask[2], mask[3], mask[4])

    local masked = {}
    -- 按块处理提高性能
    local chunk_size = 8192
    for start = 1, len, chunk_size do
        local chunk = payload:sub(start, math.min(start + chunk_size - 1, len))
        local out = {}
        for i = 1, #chunk do
            local idx = (start + i - 2) % 4 + 1
            out[i] = string.char(bxor(chunk:byte(i), mask[idx]))
        end
        masked[#masked + 1] = table.concat(out)
    end

    local frame = header .. mask_str .. table.concat(masked)
    local ok, err = self.sock:send(frame)
    return ok, err
end

function WS:send_text(data)
    return self:_send_frame(OPCODE.TEXT, data)
end

function WS:send_binary(data)
    return self:_send_frame(OPCODE.BINARY, data)
end

-- 接收一帧
-- 返回 { type = "text"|"binary"|"close"|"ping"|"pong", data = ... }, err
function WS:recv_frame(timeout)
    self.sock:settimeout(timeout or 10)

    local hdr, err = recv_exact(self.sock, 2, timeout)
    if not hdr then return nil, err end

    local b1, b2 = hdr:byte(1), hdr:byte(2)
    local fin = band(b1, 0x80) ~= 0
    local opcode = band(b1, 0x0f)
    local masked = band(b2, 0x80) ~= 0
    local payload_len = band(b2, 0x7f)

    if payload_len == 126 then
        local ext, e1 = recv_exact(self.sock, 2, timeout)
        if not ext then return nil, e1 end
        payload_len = ext:byte(1) * 256 + ext:byte(2)
    elseif payload_len == 127 then
        local ext, e2 = recv_exact(self.sock, 8, timeout)
        if not ext then return nil, e2 end
        -- 仅支持 32 位长度（足够使用）
        payload_len = ext:byte(5) * 16777216 + ext:byte(6) * 65536
            + ext:byte(7) * 256 + ext:byte(8)
    end

    local mask_key
    if masked then
        mask_key, err = recv_exact(self.sock, 4, timeout)
        if not mask_key then return nil, err end
    end

    local payload = ""
    if payload_len > 0 then
        payload, err = recv_exact(self.sock, payload_len, timeout)
        if not payload then return nil, err end
    end

    -- 服务端通常不掩码；若掩码则解掩码
    if masked and mask_key then
        local out = {}
        for i = 1, #payload do
            local idx = (i - 1) % 4 + 1
            out[i] = string.char(bxor(payload:byte(i), mask_key:byte(idx)))
        end
        payload = table.concat(out)
    end

    if opcode == OPCODE.CLOSE then
        return { type = "close", data = payload }
    elseif opcode == OPCODE.PING then
        self:_send_frame(OPCODE.PONG, payload)
        return { type = "ping", data = payload }
    elseif opcode == OPCODE.PONG then
        return { type = "pong", data = payload }
    elseif opcode == OPCODE.TEXT then
        return { type = "text", data = payload, fin = fin, opcode = opcode }
    elseif opcode == OPCODE.BINARY then
        return { type = "binary", data = payload, fin = fin, opcode = opcode }
    elseif opcode == OPCODE.CONTINUATION then
        return { type = "continuation", data = payload, fin = fin, opcode = opcode }
    end

    return nil, "未知 opcode: " .. tostring(opcode)
end

function WS:close()
    if self.sock then
        pcall(function()
            self:_send_frame(OPCODE.CLOSE, string.char(0x03, 0xe8))
        end)
        self.sock:close()
        self.sock = nil
    end
end

M.WS = WS
M.base64_encode = base64_encode

return M
