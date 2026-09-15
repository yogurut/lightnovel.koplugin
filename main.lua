--[[
轻书架 KOReader 插件 —— 入口

功能：
  * 邮箱登录 / 退出
  * 打开指定书籍（输入 ID）
  * 阅读章节（自动处理字体加密）
  * 查看日志、清理缓存

调试入口：
  「测试字体解密」会用当前账号拉取一本书的一个章节，
  并把「字体是否加载成功、正文是否为乱码」的结论写进日志，
  方便在真机上快速判断字体方案是否生效。
]]

-- 关键：所有 require 都必须能被容错。
-- KOReader 加载插件时，如果 main.lua 顶层抛错，插件会直接被跳过，
-- 但 _meta.lua 是单独读的，于是出现「插件列表里有名字、菜单里却找不到」。
-- 这里全部用 safe_require，任何一个可选模块缺失都不会拖垮整个插件。
local LOG_MODULE = "[lightnovel]"

local function safe_require(module_name, required)
    local ok, result = pcall(require, module_name)
    if not ok then
        if required then
            print(LOG_MODULE, "fatal: failed to load required module:",
                module_name, "-", tostring(result))
            return nil, false
        end
        print(LOG_MODULE, "warning: failed to load optional module:",
            module_name, "-", tostring(result))
        return nil, true
    end
    return result, true
end

-- 唯一必需的依赖
local WidgetContainer, ok = safe_require("ui/widget/container/widgetcontainer", true)
if not ok then return end

local _ = (function()
    local okg, g = pcall(require, "gettext")
    return okg and g or function(t) return t end
end)()

local UIManager      = safe_require("ui/uimanager")
local InfoMessage    = safe_require("ui/widget/infomessage")
local InputDialog    = safe_require("ui/widget/inputdialog")
local MultiInputDialog = safe_require("ui/widget/multiinputdialog")
local Trapper        = safe_require("ui/trapper")

local Log     = safe_require("lightnovel.logger")
local State   = safe_require("lightnovel.state")
local Auth    = safe_require("lightnovel.auth")
local api     = safe_require("lightnovel.api")
local Content = safe_require("lightnovel.content")
local Font    = safe_require("lightnovel.font")
local INFO    = safe_require("lightnovel.info")

-- 写一个自检标记，用来判断「KOReader 到底有没有加载这个插件」。
-- 如果 koreader/settings/lightnovel/loaded.txt 不存在，
-- 说明 main.lua 在扫描阶段就挂了（看 crash.log），或者插件目录名不对。
local function write_load_marker(stage)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/lightnovel"
        os.execute("mkdir -p '" .. dir .. "'")
        local f = io.open(dir .. "/loaded.txt", "w")
        if f then
            f:write("stage=" .. stage .. "\n")
            f:write("version=" .. tostring(INFO and INFO.version) .. "\n")
            f:write("module_loaded\n")
            f:close()
        end
    end)
end

write_load_marker("module")

-- 兜底：万一 logger 没加载成功，也要能打日志，不能让插件崩
if not Log then
    Log = {
        info = function(...) print(LOG_MODULE, "info", ...) end,
        warn = function(...) print(LOG_MODULE, "warn", ...) end,
        error = function(...) print(LOG_MODULE, "error", ...) end,
        debug = function() end,
        get_path = function() return "(logger 模块未加载)" end,
    }
end

if not INFO then
    INFO = { fullname = "轻书架", version = "0.1.0", description = "", servers = {} }
end

if not State then
    -- 状态模块加载失败时，用内存兜底，保证菜单还能打开（虽然登录不可用）
    Log.error("lightnovel.state 加载失败，插件功能将受限")
end

-- KOReader 的插件必须是 WidgetContainer 的子类，否则 pluginloader
-- 不会把它接入菜单系统（会出现「插件列表里有名字，但菜单里找不到」）。
local LightNovel = WidgetContainer:extend{
    name = "lightnovel",
    is_doc_only = false,
    fullname = INFO.fullname,
    version = INFO.version,
}

-- ============ 工具 ============

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

-- ============ 登录 ============

local function do_login()
    local dlg
    dlg = MultiInputDialog:new{
        title = _("轻书架登录"),
        fields = {
            { description = _("邮箱"), text = State:get_email() or "" },
            { description = _("密码"), text = "", password = true },
        },
        buttons = {{
            {
                text = _("取消"),
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = _("登录"),
                is_enter_default = true,
                callback = function()
                    local email = dlg:getInputText(1)
                    local password = dlg:getInputText(2)
                    UIManager:close(dlg)
                    if email == "" or password == "" then
                        toast(_("邮箱和密码不能为空"))
                        return
                    end
                    UIManager:nextTick(function()
                        Trapper:wrap(function()
                            local token, err = Auth.login(email, password)
                            if token then
                                toast(_("登录成功"))
                            else
                                toast(_("登录失败：") .. tostring(err), 6)
                            end
                        end)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ============ 阅读 ============

-- 打开某书某章
local function open_chapter(book_id, sort_num)
    Trapper:wrap(function()
        local path, chapter, warn = Content.prepare(book_id, sort_num)
        if not path then
            toast(_("打开失败：") .. tostring(chapter), 6)
            return
        end
        if warn then
            toast(warn, 6)
        end

        local ReaderUI = require("ui/reader/readerui")
        local reader = ReaderUI:new{
            document = path,
            -- 轻书架内容为 HTML，交给 crengine 渲染
            provider = "cre",
        }
        UIManager:show(reader)
    end)
end

local function ask_open_book()
    local dlg
    dlg = InputDialog:new{
        title = _("输入书籍 ID"),
        description = _("可在网页版链接 /book/12345 中找到"),
        input = State:get_last_book() or "",
        buttons = {{
            { text = _("取消"), callback = function() UIManager:close(dlg) end },
            {
                text = _("打开"),
                is_enter_default = true,
                callback = function()
                    local id = tonumber(dlg:getInputText())
                    UIManager:close(dlg)
                    if not id then
                        toast(_("请输入数字 ID"))
                        return
                    end
                    State:set_last_book(id)
                    open_chapter(id, 1)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ============ 字体自检（关键的验证入口）============

--[[
用真实接口拉一章，判断字体方案是否生效：
  * 字体是否下载成功
  * CSS 是否注入
  * 生成的文件路径（可用于人工查看）
]]
local function test_font(book_id)
    book_id = book_id or State:get_last_book() or 20287
    Trapper:wrap(function()
        local chapter, err = Content.fetch(book_id, 1)
        if not chapter then
            toast(_("拉取章节失败：") .. tostring(err), 8)
            return
        end

        local lines = {
            "书籍 ID: " .. tostring(book_id),
            "章节标题: " .. tostring(chapter.title),
            "正文字符数: " .. tostring(#(chapter.content or "")),
            "字体路径: " .. tostring(chapter.font_path),
        }

        if chapter.font_path and chapter.font_path ~= "" then
            local hash = Font.hash_from_path(chapter.font_path)
            lines[#lines + 1] = "字体 hash: " .. tostring(hash)

            local path, ferr = Font.ensure(api, chapter.font_path, api.base_url())
            if ferr then
                lines[#lines + 1] = "❌ 字体下载失败: " .. tostring(ferr)
            else
                lines[#lines + 1] = "✅ 字体已下载: " .. path

                local rpath, rerr = Font.register(hash)
                if rerr then
                    lines[#lines + 1] = "⚠️ 注册失败: " .. tostring(rerr)
                else
                    lines[#lines + 1] = "✅ 已注册到: " .. tostring(rpath)
                end
            end
        else
            lines[#lines + 1] = "⚠️ 未返回字体字段"
        end

        local text = table.concat(lines, "\n")
        Log.info("字体自检:\n%s", text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 12 })
    end)
end

-- ============ 设置 ============

-- 设置：作为菜单的二级子菜单（比自建 Menu 更可靠）
local function settings_items()
    local items = {
        {
            text = _("当前服务器"),
            help_text = State:get_server(),
            keep_menu_open = true,
        },
    }
    for _, s in ipairs(INFO.servers) do
        items[#items + 1] = {
            text = "  " .. s.label .. (State:get_server() == s.value and "  ✓" or ""),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                State:set_server(s.value)
                toast(_("已切换到：") .. s.label)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end

    items[#items + 1] = {
        text = _("预下载章节数"),
        help_text = tostring(State:get_pre_download()),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local dlg
            dlg = InputDialog:new{
                title = _("预下载章节数"),
                input = tostring(State:get_pre_download()),
                buttons = {{
                    { text = _("取消"), callback = function() UIManager:close(dlg) end },
                    {
                        text = _("确定"),
                        callback = function()
                            local n = tonumber(dlg:getInputText())
                            UIManager:close(dlg)
                            if n then State:set_pre_download(n) end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                }},
            }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
        end,
    }

    items[#items + 1] = {
        text = _("字体缓存目录"),
        help_text = Font.font_dir(),
        keep_menu_open = true,
    }

    items[#items + 1] = {
        text = _("清理字体缓存（保留最近 3 个）"),
        keep_menu_open = true,
        callback = function()
            Font.cleanup(3)
            toast(_("已清理"))
        end,
    }

    items[#items + 1] = {
        text = _("日志文件"),
        help_text = Log.get_path(),
        keep_menu_open = true,
    }

    return items
end

-- ============ 注册 ============

function LightNovel:addToMainMenu(menu_items)
    menu_items.lightnovel = {
        text = _("轻书架"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMenuItems()
        end,
    }
end

-- 菜单项用函数返回（KOReader 推荐），每次打开菜单重新求值，
-- 这样「已登录：xxx」这类动态文案才会实时更新。
function LightNovel:getMenuItems()
    -- 菜单必须永远能渲染出来，哪怕底层模块加载失败。
    -- 状态模块缺失时用安全代理，让它返回默认值而不是报错。
    local S = State or setmetatable({}, {
        __index = function()
            return function() return false end
        end,
    })

    return {
            {
                text_func = function()
                    if S:is_logged_in() then
                        return _("已登录：") .. (S:get_email() or "")
                    end
                    return _("登录")
                end,
                callback = function()
                    if S:is_logged_in() then
                        local ConfirmBox = require("ui/widget/confirmbox")
                        UIManager:show(ConfirmBox:new{
                            text = _("退出登录？"),
                            ok_callback = function()
                                Auth.logout()
                                toast(_("已退出"))
                            end,
                        })
                    else
                        do_login()
                    end
                end,
            },
            {
                text = _("打开书籍（输入 ID）"),
                enabled_func = function() return S:is_logged_in() end,
                callback = ask_open_book,
            },
            {
                text = _("测试字体解密"),
                help_text = _("拉取第 1 章并检查字体是否加载成功"),
                enabled_func = function() return S:is_logged_in() end,
                callback = function() test_font() end,
            },
            {
                text = _("默认测试书籍 ID"),
                help_text = tostring(S:get_last_book() or "—"),
                callback = function()
                    local dlg
                    dlg = InputDialog:new{
                        title = _("默认测试书籍 ID"),
                        input = tostring(S:get_last_book() or ""),
                        buttons = {{
                            { text = _("取消"), callback = function() UIManager:close(dlg) end },
                            {
                                text = _("确定"),
                                callback = function()
                                    local id = tonumber(dlg:getInputText())
                                    UIManager:close(dlg)
                                    if id then S:set_last_book(id) end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
            {
                text = _("设置"),
                sub_item_table_func = function()
                    return settings_items()
                end,
            },
            {
                text = _("关于"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = INFO.fullname .. " v" .. INFO.version .. "\n\n" .. INFO.description,
                    })
                end,
            },
    }
end

-- 插件初始化
-- 注意：不要调用 WidgetContainer.init(self)！
-- WidgetContainer 基类并没有 init 方法（它是空基类），调用会报
-- “attempt to call field 'init' (a nil value)” 导致插件初始化失败。
-- 直接写自己的初始化逻辑即可。
--
-- 另外，KOReader 只会为「文件管理器」自动注册菜单；
-- 在阅读器界面里需要自己调 ui.menu:registerToMainMenu(self)。
function LightNovel:init()
    if State and State.init then
        local ok, err = pcall(function()
            State:init()
        end)
        if not ok then
            Log.error("State:init 失败: %s", tostring(err))
        end
    end

    -- 阅读器界面下必须自己注册菜单（文件管理器是自动的）。
    -- 这一步绝对不能失败，否则用户看不到入口。
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        local rok, rerr = pcall(function()
            self.ui.menu:registerToMainMenu(self)
        end)
        if not rok then
            Log.error("菜单注册失败: %s", tostring(rerr))
            write_load_marker("menu_failed: " .. tostring(rerr))
        else
            write_load_marker("menu_ok")
        end
    else
        Log.warn("ui.menu 不可用，菜单将由 KOReader 自动注册")
        write_load_marker("no_ui_menu")
    end

    Log.info("lightnovel 插件已加载 v%s", INFO.version)
end

return LightNovel
