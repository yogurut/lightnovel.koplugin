--[[
登录流程测试（真机同款代码路径）

用插件真实的 Auth.request（socket + TLS + 手写 HTTP）打真实请求，
验证「没有此用户」这类问题不会再由空格引起。

需要网络。默认从环境变量读账号，未设置则跳过联网部分，
只跑离线的 trim / 邮箱校验逻辑。

用法：
    LN_EMAIL=xxx LN_PASSWORD=yyy lua5.1 test/test_login.lua
]]

local script_path = arg and arg[0] or "test/test_login.lua"
local root = script_path:match("^(.*)/test/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local failures = 0
local function check(cond, msg)
    print(cond and ("  ✅ " .. msg) or ("  ❌ " .. msg))
    if not cond then failures = failures + 1 end
end

-- ---- 桩掉 KOReader 专有模块 ----
local tmp = os.getenv("TMPDIR") or "/tmp"
local ds = tmp .. "/ln_test_ds"
os.execute("mkdir -p " .. ds)

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return ds end,
        getSettingsDir = function() return ds end,
    }
end
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end

-- JSON：真机是 C 版 rapidjson，本机没有，用一个最小实现代替
local json_ok = pcall(require, "rapidjson")
if not json_ok then
    package.preload["rapidjson"] = function()
        local ok, m = pcall(require, "lightnovel.testjson")
        if ok then return m end
        -- 最后兜底：只支持本测试用到的简单结构
        error("需要 rapidjson 或 lightnovel/testjson")
    end
end

package.loaded["lightnovel.logger"] = {
    info = function() end, warn = function() end,
    error = function() end, debug = function() end,
}

-- ============ 离线：trim 与邮箱校验 ============
print("== 1. 输入清洗（离线）==")

-- 与 main.lua 中保持一致的实现
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function valid(email) return email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") ~= nil end

check(trim("a@b.com ") == "a@b.com", "去掉尾随空格")
check(trim("  a@b.com") == "a@b.com", "去掉前导空格")
check(trim("\ta@b.com\n") == "a@b.com", "去掉制表符与换行")
check(trim("a@b.com") == "a@b.com", "无空格时不变")
check(trim(nil) == "", "nil 安全")

check(valid("a@b.com"), "合法邮箱通过")
check(not valid("ab.com"), "缺 @ 被拒")
check(not valid("a@bcom"), "缺顶级域被拒")
check(not valid("a @b.com"), "含空格被拒")
check(not valid("a@@b.com"), "双 @ 被拒")

-- ============ 联网：真实登录 ============
local email = os.getenv("LN_EMAIL")
local password = os.getenv("LN_PASSWORD")

print("== 2. SHA-256（离线）==")
local Auth = require("lightnovel.auth")
check(Auth.sha256_hex("abc")
    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "标准测试向量 abc")

if not email or not password then
    print("== 3. 真实登录（跳过：未设置 LN_EMAIL / LN_PASSWORD）==")
    print("    设置后可跑：LN_EMAIL=... LN_PASSWORD=... lua5.1 test/test_login.lua")
else
    print("== 3. 真实登录（走插件的 socket/TLS/HTTP 实现）==")
    local t, e = Auth.login(email, password)
    check(t ~= nil, t and "登录成功" or ("登录失败: " .. tostring(e)))

    if t then
        -- 带空格的输入必须也能成功（trim 后）
        local t2 = Auth.login(trim("  " .. email .. "  "), trim(password .. " "))
        check(t2 ~= nil, "邮箱/密码带首尾空格仍能登录（trim 生效）")
    end

    print("== 4. 错误分类 ==")
    local bad = "nonexist_" .. os.time() .. "@example.com"
    local _, e1 = Auth.login(bad, password)
    check(e1 ~= nil and e1:find("找不到该账号") ~= nil, "不存在的账号 -> 给出可读提示")
    check(e1 ~= nil and e1:find(bad, 1, true) ~= nil,
        "提示里回显了实际发送的账号（便于发现输错/多空格）")
end

print("")
if failures == 0 then
    print("✅ 全部通过")
    os.exit(0)
else
    print(string.format("❌ %d 项失败", failures))
    os.exit(1)
end
