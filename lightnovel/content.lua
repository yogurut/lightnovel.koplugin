--[[
轻书架 KOReader 插件 —— 内容获取与字体还原

核心：轻书架的章节正文是「字体映射」混淆的。
  * Content 里的字符是「被打乱码位」的写法
  * Font 字段指向一个字体，该字体在这些码位上挂的是**正确汉字**的字形
  * 因此只要用这个字体渲染，正文自然就是正确的

本模块负责：
  1. 调 GetNovelContent 拿章节（密文 + Font 路径）
  2. 确保字体已下载（见 font.lua）
  3. 把字体 CSS 注入章节 HTML
  4. 提供可交给 KOReader 渲染的 XHTML
]]

local Log = require("lightnovel.logger")
local State = require("lightnovel.state")
local api = require("lightnovel.api")
local Font = require("lightnovel.font")

local Content = {}

-- 章节内容缓存目录
local function cache_dir()
    return require("datastorage").getDataDir() .. "/lightnovel-cache"
end

local function ensure_dir(dir)
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(dir) then lfs.mkdir(dir) end
end

-- 取章节内容（含密文与字体路径）
-- 返回 { title, content(html), font_path, sort_num, book_id }
function Content.fetch(book_id, sort_num)
    -- 先确认线路可用（有缓存时几乎无开销）
    local ok_probe, Probe = pcall(require, "lightnovel.probe")
    if ok_probe and Probe and Probe.pick_server then
        Probe.pick_server()
    end

    local res, err = api.hub_call("GetNovelContent", { Bid = book_id, SortNum = sort_num })
    if not res then
        return nil, err
    end

    local chapter = res.Chapter or res
    if type(chapter) ~= "table" then
        return nil, "GetNovelContent 返回结构异常"
    end

    return {
        title = chapter.Title or ("第 " .. tostring(sort_num) .. " 章"),
        content = chapter.Content or "",
        font_path = chapter.Font,
        sort_num = chapter.SortNum or sort_num,
        book_id = chapter.BookId or book_id,
        book_name = chapter.BookName,
        chapters = chapter.Chapters,
        read_position = res.ReadPosition,
    }
end

--[[
把章节内容包装成带字体样式的 HTML。

font_dir_arg: 传给 CreDocument 的「额外资源目录」，
让 HTML 里引用相对路径的 font 能被找到（crengine 支持 file:// 相对解析）。
这里同时写入本地绝对路径，双保险。
]]
function Content.build_html(chapter, font_css)
    local css = font_css or ""
    return table.concat({
        '<?xml version="1.0" encoding="utf-8"?>',
        '<html xmlns="http://www.w3.org/1999/xhtml">',
        "<head>",
        '<meta charset="utf-8"/>',
        "<title>", (chapter.title or ""):gsub("[<>&]", ""), "</title>",
        "<style>",
        -- 基础排版：适配墨水屏
        "body{margin:0.6em 0.8em;line-height:1.7;}",
        "p{margin:0.5em 0;text-indent:2em;}",
        "p.pius1{font-size:1.15em;font-weight:bold;text-indent:0;text-align:center;margin:1em 0;}",
        "p.biaoti1{text-align:center;text-indent:0;color:#666;}",
        css,
        "</style>",
        "</head>",
        "<body class='read'>",
        chapter.content or "",
        "</body>",
        "</html>",
    })
end

-- 保存章节 HTML 到缓存，返回文件路径
function Content.save_html(book_id, sort_num, html)
    ensure_dir(cache_dir())
    ensure_dir(cache_dir() .. "/" .. tostring(book_id))
    local path = string.format("%s/%s/%d.xhtml", cache_dir(), tostring(book_id), sort_num)
    local f = io.open(path, "wb")
    if not f then return nil, "无法写入章节缓存" end
    f:write(html)
    f:close()
    return path
end

--[[
完整流程：拉取章节 → 准备字体 → 生成 HTML 文件

返回：本地 xhtml 路径, 章节信息
]]
function Content.prepare(book_id, sort_num)
    local chapter, err = Content.fetch(book_id, sort_num)
    if not chapter then
        return nil, err
    end

    local font_css, font_warn
    if chapter.font_path and chapter.font_path ~= "" then
        local hash = Font.hash_from_path(chapter.font_path)
        local _, ferr = Font.ensure(api, chapter.font_path, api.base_url())
        if ferr then
            -- 字体拿不到时正文会显示为乱码，必须明确告警
            font_warn = "字体下载失败，正文可能显示为乱码: " .. tostring(ferr)
            Log.error(font_warn)
        else
            local rpath, rerr = Font.register(hash)
            if rerr then
                Log.warn("字体注册失败: %s", tostring(rerr))
            end
            if rpath then
                font_css = Font.css(hash)
            end
        end
    end

    local html = Content.build_html(chapter, font_css)
    local path, serr = Content.save_html(book_id, sort_num, html)
    if not path then
        return nil, serr
    end

    return path, chapter, font_warn
end

return Content
