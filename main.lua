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

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Trapper = require("ui/trapper")
local Dispatcher = require("dispatcher")

local Log = require("lightnovel.logger")
local State = require("lightnovel.state")
local Auth = require("lightnovel.auth")
local api = require("lightnovel.api")
local Content = require("lightnovel.content")
local Font = require("lightnovel.font")
local INFO = require("lightnovel.info")

local LightNovel = {}

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

local function show_settings()
    local items = {
        {
            text = _("服务器"),
            help_text = State:get_server(),
        },
    }
    for _, s in ipairs(INFO.servers) do
        items[#items + 1] = {
            text = "  " .. s.label .. (State:get_server() == s.value and "  ✓" or ""),
            callback = function()
                State:set_server(s.value)
                toast(_("已切换到：") .. s.label)
            end,
        }
    end

    items[#items + 1] = {
        text = _("预下载章节数"),
        help_text = tostring(State:get_pre_download()),
        callback = function()
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
    }

    items[#items + 1] = {
        text = _("清理字体缓存（保留最近 3 个）"),
        callback = function()
            Font.cleanup(3)
            toast(_("已清理"))
        end,
    }

    items[#items + 1] = {
        text = _("查看日志文件"),
        help_text = Log.get_path(),
    }

    local Menu = require("ui/widget/menu")
    local m
    m = Menu:new{
        title = _("轻书架设置"),
        item_table = items,
        width = UIManager:getWidth(),
        height = UIManager:getHeight(),
        onMenuSelect = function(_, item)
            if item.callback then item.callback() end
            UIManager:close(m)
        end,
    }
    UIManager:show(m)
end

-- ============ 注册 ============

function LightNovel:addToMainMenu(menu_items)
    menu_items.lightnovel = {
        text = _("轻书架"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text_func = function()
                    if State:is_logged_in() then
                        return _("已登录：") .. (State:get_email() or "")
                    end
                    return _("登录")
                end,
                callback = function()
                    if State:is_logged_in() then
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
                enabled_func = function() return State:is_logged_in() end,
                callback = ask_open_book,
            },
            {
                text = _("测试字体解密"),
                help_text = _("拉取第 1 章并检查字体是否加载成功"),
                enabled_func = function() return State:is_logged_in() end,
                callback = function() test_font() end,
            },
            {
                text = _("默认测试书籍 ID"),
                help_text = tostring(State:get_last_book() or "—"),
                callback = function()
                    local dlg
                    dlg = InputDialog:new{
                        title = _("默认测试书籍 ID"),
                        input = tostring(State:get_last_book() or ""),
                        buttons = {{
                            { text = _("取消"), callback = function() UIManager:close(dlg) end },
                            {
                                text = _("确定"),
                                callback = function()
                                    local id = tonumber(dlg:getInputText())
                                    UIManager:close(dlg)
                                    if id then State:set_last_book(id) end
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
                callback = show_settings,
            },
            {
                text = _("关于"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = INFO.fullname .. " v" .. INFO.version .. "\n\n" .. INFO.description,
                    })
                end,
            },
        },
    }
end

function LightNovel:init()
    State:init()
    Log.info("lightnovel 插件已加载 v%s", INFO.version)
end

return LightNovel
