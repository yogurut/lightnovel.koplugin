--[[
轻书架 KOReader 插件 —— 服务器连通性探测

登录前先探测各线路，挑一个能用的。

判定标准（关键）：
  用「登录接口 + 空 body」探测。
    /api/user/login 返回 400 / 405 / 500 都算「服务器活着」
    （说明路由存在，只是请求内容不对）
    只有超时 / DNS 失败 / 连不上才算「不可用」

注意：不要用 GET 探测，也不要看 4xx 就判失败。
]]

local Log = require("lightnovel.logger")
local INFO = require("lightnovel.info")

local Probe = {}

-- 探测结果缓存（秒），避免频繁探测
local CACHE_TTL = 300
local cache = { time = 0, url = nil, results = nil }

--[[
探测单个域名。
返回: ok(boolean), ms(number), err(string|nil)
]]
local function probe_one(url, timeout)
    local Auth = require("lightnovel.auth")

    local t0 = os.clock()
    local res, err = Auth.request(url .. "/api/user/login", {
        method = "POST",
        body = "{}",
        timeout = timeout or 8,
    })
    local ms = os.clock() - t0

    if not res then
        return false, ms, tostring(err)
    end

    local st = tonumber(res.status) or 0
    -- 服务器活着：返回了任意 HTTP 状态且不是 5xx 网关类错误
    -- 400/401/405/500（业务错误）都说明服务在
    if st >= 200 and st < 600 then
        return true, ms, nil
    end
    return false, ms, string.format("HTTP %d", st)
end

--[[
探测全部线路，按延迟升序返回。
opts.timeout  单次超时（秒）
opts.force    忽略缓存
]]
function Probe.run(opts)
    opts = opts or {}
    local timeout = opts.timeout or 8
    local servers = INFO.servers or {}

    local results = {}
    for _, s in ipairs(servers) do
        local ok, ms, err = probe_one(s.value, timeout)
        results[#results + 1] = {
            label = s.label,
            url = s.value,
            ok = ok,
            ms = ms,
            err = err,
        }
        Log.info("探测线路 %s -> %s", s.value,
            ok and string.format("可用 (%.2fs)", ms) or ("不可用: " .. tostring(err)))
    end

    -- 可用的排前面，同组内按延迟升序
    table.sort(results, function(a, b)
        if a.ok ~= b.ok then return a.ok end
        return (a.ms or 999) < (b.ms or 999)
    end)

    cache.time = os.time()
    cache.results = results
    cache.url = (results[1] and results[1].ok) and results[1].url or nil

    return results
end

--[[
返回可用线路列表（优先用缓存）。
]]
function Probe.available(force)
    local now = os.time()
    if not force and cache.results and (now - cache.time) < CACHE_TTL then
        return cache.url, cache.results
    end
    local results = Probe.run()
    return cache.url, results
end

--[[
选一个能用的线路并写入 State。
返回: url(可用线路 | 原值), switched(boolean), results
]]
function Probe.pick_server()
    local State = require("lightnovel.state")
    local current = State:get_server()

    local best, results = Probe.available()

    if not best then
        -- 全部不可用：保持原设置，交给上层报错
        Log.warn("所有线路均不可用，继续使用 %s", current)
        return current, false, results
    end

    if best ~= current then
        Log.info("线路择优：%s -> %s", current, best)
        State:set_server(best)
        return best, true, results
    end

    return current, false, results
end

--[[清空缓存（手动切换线路后调用）]]
function Probe.clear()
    cache.time = 0
    cache.url = nil
    cache.results = nil
end

--[[把探测结果格式化成可读文本（给设置页用）]]
function Probe.format_results(results)
    local lines = {}
    for _, r in ipairs(results or {}) do
        lines[#lines + 1] = string.format("%s  %s%s",
            r.ok and "✅" or "❌",
            r.label,
            r.ok and string.format("  %.2fs", r.ms or 0) or ("  " .. tostring(r.err)))
    end
    if #lines == 0 then return "（无结果）" end
    return table.concat(lines, "\n")
end

return Probe
