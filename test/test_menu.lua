--[[
菜单注册测试（离线，不需要 KOReader）

验证插件是否能被 KOReader 正常加载并注册菜单。
这是「插件列表里有名字、但菜单里找不到」这类问题的回归测试。

用法：
    lua5.1 test/test_menu.lua

依赖：test/menu-stubs/ 下的 KOReader 模块桩。
]]

-- 定位仓库根目录（本文件在 test/ 下）
local script_path = arg and arg[0] or "test/test_menu.lua"
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

print("== 1. 加载 main.lua ==")
local ok, plugin = pcall(dofile, root .. "/main.lua")
check(ok, "main.lua 可加载" .. (ok and "" or (": " .. tostring(plugin))))
if not ok then os.exit(1) end
check(type(plugin) == "table", "返回 table")

print("== 2. 元信息 ==")
check(plugin.name == "lightnovel", "name = lightnovel（实际: " .. tostring(plugin.name) .. "）")
check(plugin.is_doc_only == false, "is_doc_only = false（否则只在阅读器里出现）")
check(type(plugin.fullname) == "string", "有 fullname")

print("== 3. WidgetContainer 子类 ==")
-- 关键：必须是 WidgetContainer:extend 出来的，否则 pluginloader 不接管菜单
check(plugin.new ~= nil, "具备 new()（WidgetContainer:extend 的产物）")

print("== 4. 实例化与 init ==")
local registered = false
local fake_ui = {
    menu = {
        registerToMainMenu = function(_, p)
            registered = true
        end,
    },
}
local inst
ok, inst = pcall(function() return plugin:new{ ui = fake_ui } end)
check(ok, "实例化成功" .. (ok and "" or (": " .. tostring(inst))))
if not ok then os.exit(1) end

ok = pcall(function() inst:init() end)
check(ok, "init() 无异常" .. (ok and "" or (": " .. tostring(inst))))
check(registered, "init() 中调用了 ui.menu:registerToMainMenu(self)")
check(inst._wc_inited == true, "调用了 WidgetContainer.init(self)")

print("== 5. addToMainMenu ==")
local menu_items = {}
ok = pcall(function() inst:addToMainMenu(menu_items) end)
check(ok, "addToMainMenu 无异常" .. (ok and "" or (": " .. tostring(inst))))

local item = menu_items.lightnovel
check(item ~= nil, "注册了 menu_items.lightnovel")
if item then
    check(type(item.text) == "string", "有 text")
    check(type(item.sorting_hint) == "string",
        "有 sorting_hint（实际: " .. tostring(item.sorting_hint) .. "）")
    check(type(item.sub_item_table_func) == "function" or type(item.sub_item_table) == "table",
        "有子菜单")
end

print("== 6. 子菜单可展开 ==")
if item and type(item.sub_item_table_func) == "function" then
    local ok2, sub = pcall(item.sub_item_table_func)
    check(ok2, "sub_item_table_func() 可调用")
    if ok2 and type(sub) == "table" then
        check(#sub > 0, "子菜单项数 > 0（实际 " .. #sub .. "）")
        for i, it in ipairs(sub) do
            local text = it.text
            if not text and type(it.text_func) == "function" then
                local ok3, t = pcall(it.text_func)
                text = ok3 and t or nil
            end
            print(string.format("     %d. %s", i, tostring(text)))
        end
        -- 二级菜单也要能展开（设置）
        for _, it in ipairs(sub) do
            if type(it.sub_item_table_func) == "function" then
                local ok4, s2 = pcall(it.sub_item_table_func)
                check(ok4, "二级子菜单（" .. tostring(it.text) .. "）可展开")
                if ok4 and type(s2) == "table" then
                    check(#s2 > 0, "  二级项数 > 0（实际 " .. #s2 .. "）")
                end
            end
        end
    end
end

print("")
if failures == 0 then
    print("✅ 全部通过 —— 插件应能在 KOReader 菜单中正常显示")
    os.exit(0)
else
    print(string.format("❌ %d 项失败", failures))
    os.exit(1)
end
