--[[
轻书架 KOReader 插件 —— SignalR 客户端（MessagePack over WebSocket）

轻书架的后端是 ASP.NET Core SignalR，Hub 路径 /hub/api，传输协议 MessagePack。
本模块实现最小可用的 SignalR 客户端：

  1. 通过 HTTP negotiate 获取 connectionToken
  2. 建立 WebSocket（ws/wss）连接
  3. 握手：发送 {"protocol":"messagepack", version:1} + \x1e
  4. 调用 Hub 方法：MessagePack 编码的 Invocation 消息 + \x1e
  5. 解析返回的 Completion 消息

依赖：纯 Lua WebSocket 实现（lightnovel.websocket）
]]

local rapidjson = require("rapidjson")
local Log = require("lightnovel.logger")
local State = require("lightnovel.state")
local mp = require("lightnovel.msgpack")
local WS = require("lightnovel.websocket")

local SignalR = {}

local RS = "\30"  -- 0x1e Record Separator

-- MessageType（SignalR 协议）
local MSG = {
    INVOCATION = 1,
    STREAM_ITEM = 2,
    COMPLETION = 3,
    STREAM_INVOCATION = 4,
    CANCEL_INVOCATION = 5,
    PING = 6,
    CLOSE = 7,
}

-- ============ 连接对象 ============

local Conn = {}
Conn.__index = Conn

function Conn.new(url, token)
    return setmetatable({
        base_url = url,       -- https://api.lightnovel.life
        token = token,
        ws = nil,
        invocation_id = 0,
        connected = false,
    }, Conn)
end

-- 解析 negotiate 响应，拿到 connectionToken 与可用传输方式
function Conn:negotiate()
    local url = self.base_url .. "/hub/api/negotiate?negotiateVersion=1"
    local Auth = require("lightnovel.auth")

    local res, err = Auth.request(url, {
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
            ["Content-Length"] = "0",
        },
        body = nil,
    })
    if not res then
        return nil, "negotiate 失败: " .. tostring(err)
    end
    if res.status ~= 200 then
        return nil, string.format("negotiate HTTP %d: %s", res.status, tostring(res.body):sub(1, 150))
    end

    local ok, data = pcall(rapidjson.decode, res.body)
    if not ok or type(data) ~= "table" then
        return nil, "negotiate 响应解析失败: " .. tostring(res.body):sub(1, 150)
    end

    if not data.connectionToken then
        return nil, data.error or "negotiate 未返回 connectionToken"
    end

    self.connection_token = data.connectionToken
    self.available_transports = data.availableTransports
    return data
end

-- 建立 WebSocket 连接
function Conn:connect()
    local neg, err = self:negotiate()
    if not neg then return nil, err end

    -- 构造 WebSocket URL（https -> wss）
    local ws_url = self.base_url
        :gsub("^https://", "wss://")
        :gsub("^http://", "ws://")
    ws_url = ws_url .. "/hub/api?id=" .. self.connection_token

    Log.info("正在建立 WebSocket 连接...")
    local sock, werr = WS.connect(ws_url, {
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
        },
    })
    if not sock then
        return nil, "WebSocket 连接失败: " .. tostring(werr)
    end
    self.ws = sock

    -- SignalR 握手（文本帧 JSON + RS）
    local handshake = rapidjson.encode({ protocol = "messagepack", version = 1 }) .. RS
    local ok, herr = sock:send_text(handshake)
    if not ok then
        return nil, "握手发送失败: " .. tostring(herr)
    end

    -- 读取握手响应
    local frame, rerr = sock:recv_frame(10)
    if not frame then
        return nil, "握手无响应: " .. tostring(rerr)
    end

    self.connected = true
    Log.info("SignalR 连接已建立")
    return true
end

-- 调用 Hub 方法，同步等待 Completion 响应
-- args: 参数数组（Lua table，按位置）
function Conn:invoke(target, args, timeout)
    if not self.connected then
        return nil, "连接未建立"
    end

    self.invocation_id = self.invocation_id + 1
    local inv_id = tostring(self.invocation_id)

    -- 构造 Invocation 消息： { 1, { type:1, invocationId, target, arguments } }
    -- arguments 与 target 必须编码为 map 结构，用 as_map 保证
    local arguments = {}
    for i, v in ipairs(args or {}) do
        arguments[i] = v
    end

    local payload = mp.as_map({
        type = MSG.INVOCATION,
        invocationId = inv_id,
        target = target,
        arguments = arguments,
    })

    -- SignalR 二进制帧使用 varint 前缀长度；用 MessagePack 的 bin 兼容格式：
    -- 实际实现中，SignalR 的 MessagePack 帧直接是 [varint length][payload]，
    -- 但通过 WebSocket 发送时使用 Binary 帧承载 payload（长度由 WS 层处理）。
    local encoded = mp.encode(payload)
    local ok, serr = self.ws:send_binary(encoded)
    if not ok then
        return nil, "发送调用失败: " .. tostring(serr)
    end

    -- 等待 Completion
    local deadline = os.time() + (timeout or 20)
    while os.time() <= deadline do
        local frame, ferr = self.ws:recv_frame(5)
        if frame then
            if frame.type == "text" then
                -- 文本帧可能是 JSON 类型的 Ping/Close，忽略
                Log.debug("收到文本帧: %s", tostring(frame.data):sub(1, 100))
            elseif frame.type == "binary" then
                local msgs = self:_parse_frames(frame.data)
                for _, msg in ipairs(msgs) do
                    local result, done, rerr = self:_handle_message(msg, inv_id)
                    if done then
                        if rerr then return nil, rerr end
                        return result
                    end
                end
            elseif frame.type == "close" then
                self.connected = false
                return nil, "连接已被服务端关闭"
            end
        elseif ferr == "timeout" then
            -- 继续等待
        else
            return nil, "接收失败: " .. tostring(ferr)
        end
    end

    return nil, "调用超时（" .. tostring(target) .. "）"
end

-- 解析一段二进制数据中可能包含的多个 MessagePack 消息（以 RS 或长度分隔）
function Conn:_parse_frames(data)
    local out = {}

    -- SignalR MessagePack 帧格式：[varint 长度][payload]，无 RS 分隔符。
    -- 逐个按 varint 长度切分。
    local pos = 1
    while pos <= #data do
        local len, new_pos = self:_read_varint(data, pos)
        if not len or len <= 0 then break end
        if new_pos + len - 1 > #data then
            -- 数据不完整
            break
        end
        local payload = data:sub(new_pos, new_pos + len - 1)
        local ok, msg = pcall(mp.decode, payload)
        if ok and msg then
            out[#out + 1] = msg
        else
            Log.warn("MessagePack 解码失败，跳过该帧")
        end
        pos = new_pos + len
    end

    -- 若无长度前缀（服务端直接发裸 MessagePack），回退整体解析
    if #out == 0 then
        local ok, msg = pcall(mp.decode, data)
        if ok and msg then out[#out + 1] = msg end
    end

    return out
end

-- 读取 varint（LEB128）
function Conn:_read_varint(data, pos)
    local result = 0
    local shift = 0
    while true do
        local b = data:byte(pos)
        if not b then return nil, pos end
        result = result + (b % 128) * (2 ^ shift)
        pos = pos + 1
        shift = shift + 7
        if b < 128 then break end
        if shift > 63 then return nil, pos end
    end
    return result, pos
end

-- 处理单条消息，返回 (result, is_completion, error)
function Conn:_handle_message(msg, inv_id)
    if type(msg) ~= "table" then return nil, false end

    local mtype = msg.type

    if mtype == MSG.COMPLETION then
        if tostring(msg.invocationId) == tostring(inv_id) then
            if msg.error then
                return nil, true, msg.error
            end
            return msg.result, true
        end
    elseif mtype == MSG.PING then
        -- 忽略
    elseif mtype == MSG.CLOSE then
        self.connected = false
        return nil, false, "服务端要求关闭连接"
    end

    return nil, false
end

function Conn:close()
    if self.ws then
        pcall(function()
            local close_msg = mp.encode(mp.as_map({ type = MSG.CLOSE }))
            self.ws:send_binary(close_msg)
        end)
        self.ws:close()
        self.ws = nil
    end
    self.connected = false
end

-- ============ 对外接口 ============

-- 建立连接（自动使用登录态 Token）
function SignalR.connect()
    Auth = require("lightnovel.auth")
    local token, err = Auth.ensure_token()
    if not token then
        return nil, err or "未登录"
    end

    local conn = Conn.new(State:get_server(), token)
    local ok, cerr = conn:connect()
    if not ok then
        return nil, cerr
    end
    return conn
end

-- 便捷方法：连接 -> 调用 -> 关闭
function SignalR.call(target, args, timeout)
    local conn, err = SignalR.connect()
    if not conn then return nil, err end

    local result, ierr = conn:invoke(target, args, timeout)
    conn:close()

    if result == nil and ierr then
        return nil, ierr
    end
    return result
end

SignalR.Conn = Conn
SignalR.MSG = MSG

return SignalR
