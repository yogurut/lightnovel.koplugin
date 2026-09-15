--[[
轻书架 KOReader 插件 —— 鉴权（邮箱 + 密码登录）

登录流程：
  1. POST /api/user/login  { email, password: sha256(password) }
  2. 响应 { Success, Response: { Token, RefreshToken } }
  3. 后续请求用 Bearer Token；Token 过期用 RefreshToken 换取

网络层基于 LuaSocket/LuaSec，与 KOReader 内置能力一致。
]]

local socket = require("socket")
local ssl = require("ssl")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local Log = require("lightnovel.logger")
local State = require("lightnovel.state")

local Auth = {}

-- SHA-256：优先使用 KOReader 内置 ffi/sha2（如有），否则回退到纯 Lua 实现。
-- 注意：ffi/sha2 属于 koreader-base submodule，不同固件版本提供情况不一致，
-- 因此这里做运行时探测，并且默认使用纯 Lua 实现（已通过标准测试向量验证）。
local sha256_hex

do
    local pure = require("lightnovel.sha256")
    sha256_hex = pure.hex

    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and type(sha2) == "table" and type(sha2.sha256) == "function" then
        -- ffi/sha2 的 sha256 返回二进制摘要，需要转成 hex
        local probe_ok, probe = pcall(sha2.sha256, "abc")
        if probe_ok and type(probe) == "string" and #probe == 32 then
            sha256_hex = function(s)
                local d = sha2.sha256(s)
                return (d:gsub(".", function(c)
                    return string.format("%02x", string.byte(c))
                end))
            end
            Log.info("使用 ffi/sha2 SHA-256 实现")
        end
    end

    if sha256_hex == pure.hex then
        Log.info("使用纯 Lua SHA-256 实现")
    end
end

Auth.sha256_hex = sha256_hex

-- ============ HTTP 请求底层 ============

-- 统一 HTTP 请求（支持 http/https、GET/POST、自定义 header）
function Auth.request(url, opts)
    opts = opts or {}
    local method = opts.method or "POST"
    local headers = opts.headers or {}
    local body = opts.body

    local response_chunks = {}
    local scheme, host, port, path

    if url:match("^https://") then
        scheme = "https"
        url = url:sub(9)
    else
        scheme = "http"
        url = url:sub(8)
    end

    local host_port, rest = url:match("^([^/]+)(/.*)$")
    if not host_port then host_port = url; rest = "/" end
    host, port = host_port:match("^([^:]+):(%d+)$")
    if not host then
        host = host_port
        port = (scheme == "https") and 443 or 80
    end
    path = rest or "/"

    headers["Host"] = host
    headers["Accept"] = headers["Accept"] or "application/json"
    headers["User-Agent"] = headers["User-Agent"]
        or "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    -- 轻书架要求携带设备指纹
    headers["x-id"] = headers["x-id"] or ("koreader_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999)))
    headers["Accept-Encoding"] = "identity"  -- 不使用 gzip，简化解析

    if body and not headers["Content-Type"] then
        headers["Content-Type"] = "application/json"
    end
    if body then
        headers["Content-Length"] = tostring(#body)
    end

    -- 构造请求头文本
    local header_lines = { method .. " " .. path .. " HTTP/1.1" }
    for k, v in pairs(headers) do
        header_lines[#header_lines + 1] = k .. ": " .. tostring(v)
    end
    local request_text = table.concat(header_lines, "\r\n") .. "\r\n\r\n"
    if body then
        request_text = request_text .. body
    end

    local sock
    if scheme == "https" then
        local params = {
            mode = "client",
            protocol = "tlsv1_2",
            verify = "none",           -- 墨水屏设备证书库往往不完整，跳过校验
            options = "all",
        }
        sock, err = socket.tcp()
        if not sock then
            return nil, "无法创建 socket: " .. tostring(err)
        end
        sock:settimeout(opts.timeout or 30)
        local ok, e = sock:connect(host, port)
        if not ok then
            sock:close()
            return nil, "连接失败: " .. tostring(e)
        end
        sock, err = ssl.wrap(sock, params)
        if not sock then
            return nil, "TLS 握手失败: " .. tostring(err)
        end
        local ok2, e2 = sock:dohandshake()
        if not ok2 then
            sock:close()
            return nil, "TLS 握手失败: " .. tostring(e2)
        end
    else
        sock, err = socket.tcp()
        if not sock then
            return nil, "无法创建 socket: " .. tostring(err)
        end
        sock:settimeout(opts.timeout or 30)
        local ok, e = sock:connect(host, port)
        if not ok then
            sock:close()
            return nil, "连接失败: " .. tostring(e)
        end
    end

    local ok_send, send_err = sock:send(request_text)
    if not ok_send then
        sock:close()
        return nil, "发送请求失败: " .. tostring(send_err)
    end

    -- 读取响应（处理 chunked 与 Content-Length）
    local raw_chunks = {}
    while true do
        local chunk, recv_err, partial = sock:receive(4096)
        if chunk then
            raw_chunks[#raw_chunks + 1] = chunk
        elseif partial and #partial > 0 then
            raw_chunks[#raw_chunks + 1] = partial
            break
        else
            if recv_err and recv_err ~= "closed" and recv_err ~= "timeout" then
                Log.warn("接收响应异常: %s", tostring(recv_err))
            end
            break
        end
    end
    sock:close()

    local raw = table.concat(raw_chunks)
    if raw == "" then
        return nil, "响应为空"
    end

    -- 分离 header 与 body
    local header_end = raw:find("\r\n\r\n", 1, true)
    if not header_end then
        return nil, "响应格式异常（无 header 分隔）"
    end
    local header_text = raw:sub(1, header_end - 1)
    local body_text = raw:sub(header_end + 4)

    local status = tonumber(header_text:match("^HTTP/%d%.%d%s+(%d+)"))
    local is_chunked = header_text:lower():find("transfer%-encoding:%s*chunked") ~= nil

    if is_chunked then
        -- 解析 chunked 编码
        local decoded = {}
        local pos = 1
        while true do
            local line_end = body_text:find("\r\n", pos, true)
            if not line_end then break end
            local size_hex = body_text:sub(pos, line_end - 1):gsub("%s", "")
            local size = tonumber(size_hex, 16)
            if not size or size == 0 then break end
            decoded[#decoded + 1] = body_text:sub(line_end + 2, line_end + 1 + size)
            pos = line_end + 2 + size + 2
            if pos > #body_text then break end
        end
        body_text = table.concat(decoded)
    end

    return {
        status = status or 0,
        headers = header_text,
        body = body_text,
    }
end

-- ============ 业务接口 ============

local function server()
    return State:get_server()
end

-- 登录：email + 明文密码
function Auth.login(email, password)
    local body = rapidjson.encode({
        email = email,
        password = sha256_hex(password),
    })

    Log.info("正在登录: %s", email)
    local res, err = Auth.request(server() .. "/api/user/login", {
        method = "POST",
        body = body,
    })
    if not res then
        return nil, err
    end

    local ok, data = pcall(rapidjson.decode, res.body)
    if not ok or type(data) ~= "table" then
        return nil, "登录响应解析失败: " .. tostring(res.body):sub(1, 200)
    end

    if not data.Success then
        return nil, data.Msg or ("登录失败 (HTTP " .. tostring(res.status) .. ")")
    end

    local resp = data.Response or {}
    if not resp.Token then
        return nil, "登录成功但未返回 Token"
    end

    State:save_auth(resp.Token, resp.RefreshToken, email, resp.UserName or "")
    Log.info("登录成功")
    return resp.Token
end

-- 用 RefreshToken 换新 Token
function Auth.refresh()
    local rt = State:get_refresh_token()
    if not rt or rt == "" then
        return nil, "无 RefreshToken"
    end

    local body = rapidjson.encode({ token = rt })
    local res, err = Auth.request(server() .. "/api/user/refresh_token", {
        method = "POST",
        body = body,
    })
    if not res then
        return nil, err
    end

    local ok, data = pcall(rapidjson.decode, res.body)
    if not ok or type(data) ~= "table" or not data.Success then
        State:clear_auth()
        return nil, (type(data) == "table" and data.Msg) or "Token 刷新失败"
    end

    local resp = data.Response or {}
    State:save_auth(resp.Token, rt, State:get_email(), State:get_user_name())
    Log.info("Token 刷新成功")
    return resp.Token
end

-- 确保有可用 Token（必要时刷新）
function Auth.ensure_token()
    if State:get_token() ~= "" then
        return State:get_token()
    end
    local tok, err = Auth.refresh()
    if tok then return tok end
    return nil, err
end

function Auth.logout()
    State:clear_auth()
    Log.info("已退出登录")
end

return Auth
