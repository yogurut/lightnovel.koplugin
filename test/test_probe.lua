--[[
服务器探测逻辑测试（离线，不联网）

用桩模拟 Auth.request 的各种返回，验证 Probe 的判定与择优逻辑：
  * 哪些响应算「可用」
  * 是否按延迟升序排序
  * 当前线路挂掉时是否会自动切换

用法：
    lua5.1 test/test_probe.lua
]]

local script_path = arg and arg[0] or "test/test_probe.lua"
local root = script_path:match("^(.*)/test/[^/]+$") or "."
local stubs = root .. "/test/menu-stubs"

package.path = table.concat({
    stubs .. "/?.lua",
    stubs .. "/?/init.lua",
    root .. "/?.lua",
    package.path,
}, ";")

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ✅ " .. msg)
    else
        print("  ❌ " .. msg)
        failures = failures + 1
    end
end

-- ---- 注入可控的 Auth.request ----
local fake = { handler = nil }
package.loaded["lightnovel.auth"] = {
    request = function(url, opts)
        return fake.handler(url, opts)
    end,
}
package.loaded["lightnovel.logger"] = {
    info = function() end, warn = function() end,
    error = function() end, debug = function() end,
    get_path = function() return "/dev/null" end,
}

local Probe = require("lightnovel.probe")

print("== 1. 响应判定 ==")
local cases = {
    { name = "200 正常",       status = 200, ok = true },
    { name = "400 参数错误",   status = 400, ok = true },
    { name = "401 未授权",     status = 401, ok = true },
    { name = "405 方法不对",   status = 405, ok = true },
    { name = "500 业务错误",   status = 500, ok = true },
    { name = "502 网关错误",   status = 502, ok = true },
}
for _, c in ipairs(cases) do
    fake.handler = function() return { status = c.status, body = "" } end
    local results = Probe.run()
    check(results[1].ok == c.ok,
        string.format("%s (HTTP %d) -> %s", c.name, c.status, c.ok and "可用" or "不可用"))
end

print("== 2. 连接失败 ==")
fake.handler = function() return nil, "连接失败: timeout" end
local r = Probe.run()
check(r[1].ok == false, "连接失败 -> 不可用")
check(r[1].err ~= nil, "记录了错误原因: " .. tostring(r[1].err))

print("== 3. 排序（可用优先，延迟升序）==")
local delays = {
    ["https://api.lightnovel.life"] = 0.9,
    ["https://cf-api.lightnovel.life"] = 0.2,
}
local statuses = {
    ["https://api.lightnovel.life"] = 200,
    ["https://cf-api.lightnovel.life"] = nil,   -- nil = 失败
}
local function make_handler(status_map, delay_map)
    return function(url)
        local host = url:match("^(https://[^/]+)")
        if status_map[host] == nil then
            return nil, "timeout"
        end
        -- 用忙等模拟耗时
        local target = delay_map[host] or 0
        local t0 = os.clock()
        while os.clock() - t0 < target * 0.05 do end
        return { status = status_map[host], body = "" }
    end
end

fake.handler = make_handler({ ["https://api.lightnovel.life"] = nil,
                              ["https://cf-api.lightnovel.life"] = 200 },
                            { ["https://cf-api.lightnovel.life"] = 0.1 })
r = Probe.run()
check(r[1].ok == true, "可用的排第一（" .. tostring(r[1].url) .. "）")
check(r[2].ok == false, "失败的排最后")

print("== 4. 择优切换 ==")
local servers = require("lightnovel.info").servers
check(#servers >= 2, "至少配置了 2 条线路（实际 " .. #servers .. "）")
for _, s in ipairs(servers) do
    print("     " .. s.label .. " -> " .. s.value)
end

local State = require("lightnovel.state")
-- 模拟：当前线路挂了，另一条可用
local current = State:get_server()
local other
for _, s in ipairs(servers) do
    if s.value ~= current then other = s.value end
end
fake.handler = make_handler({ [current] = nil, [other] = 200 }, { [other] = 0.05 })
Probe.clear()
local picked, switched = Probe.pick_server()
check(picked == other, "自动切到可用线路（" .. tostring(picked) .. "）")
check(switched == true, "返回 switched=true")
check(State:get_server() == other, "状态已更新")

print("== 5. 全部挂掉时保持原设置 ==")
fake.handler = function() return nil, "timeout" end
Probe.clear()
local before = State:get_server()
local p2, sw2 = Probe.pick_server()
check(sw2 == false, "不切换")
check(State:get_server() == before, "保持原线路")

print("")
if failures == 0 then
    print("✅ 全部通过")
    os.exit(0)
else
    print(string.format("❌ %d 项失败", failures))
    os.exit(1)
end
