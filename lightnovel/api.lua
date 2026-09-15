--[[
轻书架 KOReader 插件 —— 网络适配层

把 auth.lua 的底层 HTTP 封装成更顺手的接口，并统一注入鉴权头。
所有对外请求都会自动带上 Bearer Token（若已登录）。
]]

local rapidjson = require("rapidjson")
local Auth = require("lightnovel.auth")
local State = require("lightnovel.state")
local Log = require("lightnovel.logger")

local api = {}

-- 当前服务器基址
function api.base_url()
    return State:get_server()
end

-- 构造带鉴权的头
local function auth_headers(extra)
    local h = extra or {}
    local token = State:get_token()
    if token and token ~= "" then
        h["Authorization"] = "Bearer " .. token
    end
    return h
end

--[[
底层 HTTP 请求。

opts:
  method   : "GET" / "POST"（默认 GET）
  body     : 请求体字符串
  headers  : 额外头
  timeout  : 秒

返回：
  body_string, nil     成功
  nil, err_string      失败

成功判定：HTTP 2xx 且（若是 JSON 且有 Success 字段）Success == true
]]
function api.request(url, opts)
    opts = opts or {}
    opts.headers = auth_headers(opts.headers)
    if opts.method == nil then opts.method = "GET" end

    local res, err = Auth.request(url, opts)
    if not res then
        return nil, err
    end

    if res.status < 200 or res.status >= 300 then
        return nil, string.format("HTTP %d: %s", res.status, tostring(res.body):sub(1, 200))
    end

    return res.body, nil
end

-- GET，返回原始 body
function api.get(url, opts)
    opts = opts or {}
    opts.method = "GET"
    return api.request(url, opts)
end

-- POST JSON，返回解析后的 table
function api.post_json(url, tbl, opts)
    opts = opts or {}
    opts.method = "POST"
    opts.headers = auth_headers(opts.headers)
    opts.headers["Content-Type"] = "application/json"
    opts.body = rapidjson.encode(tbl or {})

    local res, err = Auth.request(url, opts)
    if not res then return nil, err end
    if res.status < 200 or res.status >= 300 then
        return nil, string.format("HTTP %d: %s", res.status, tostring(res.body):sub(1, 200))
    end

    local ok, data = pcall(rapidjson.decode, res.body)
    if not ok then
        return nil, "JSON 解析失败: " .. tostring(res.body):sub(1, 200)
    end
    if type(data) == "table" and data.Success == false then
        return nil, data.Msg or "接口返回失败"
    end
    return data, nil
end

-- 下载二进制（字体、封面等），返回原始字符串
function api.download(url, opts)
    opts = opts or {}
    opts.method = "GET"
    opts.timeout = opts.timeout or 60
    return api.request(url, opts)
end

-- 走 SignalR Hub 的 RPC（由 signalr 模块提供，这里做薄封装）
function api.hub_call(target, args, timeout)
    local ok, SignalR = pcall(require, "lightnovel.signalr")
    if not ok then
        return nil, "signalr 模块加载失败: " .. tostring(SignalR)
    end
    local res, err = SignalR.call(target, args, timeout)
    if not res then
        Log.warn("hub_call %s 失败: %s", target, tostring(err))
    end
    return res, err
end

return api
