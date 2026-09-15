--[[
轻书架 KOReader 插件 —— 字体加密还原模块

原理
----
轻书架的服务端对章节正文做了「字体映射」混淆：

1. 服务端按书生成一个字体（`/font/{hash}.woff2`），把 cmap 打乱
   —— 即码位 `U+6C9B`（'沛'）上挂的其实是「魔」的字形。
2. 正文 `Content` 里用被替换后的码位书写（「魔女茶会」→「沛际茶姜」）。
3. 前端用 `@font-face{font-family:read;src:url(/font/{hash}.woff2)}` 渲染，
   字形恰好是正确汉字，于是读者看到的是解密后的文字。

对 KOReader 来说**不需要做任何字符还原**：只要把正文用同一个字体渲染即可。
本模块负责：

* 下载字体（优先 `.ttf`，服务端直接提供，避免 woff2/brotli 依赖）
* 缓存到 KOReader 的字体目录
* 生成 / 复用 CSS `@font-face` 片段
* 处理 name 表为空的问题（用固定文件名 + 生成 style 指定 family）

注意：映射会随服务端轮换（hash 变化），因此字体必须**按需下载并缓存**，
不能预置静态映射表。
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("lightnovel.logger")
local _ = require("gettext")

local Font = {}

-- 字体缓存目录（KOReader 的 data 目录下，随插件走）
local function font_dir()
    local base = require("datastorage").getDataDir()
    return base .. "/lightnovel-fonts"
end

Font.font_dir = font_dir

-- 确保缓存目录存在
local function ensure_dir(dir)
    if not lfs.attributes(dir) then
        lfs.mkdir(dir)
    end
end

-- 从 /font/xxx.woff2 提取 hash
function Font.hash_from_path(font_path)
    if type(font_path) ~= "string" then return nil end
    local hash = font_path:match("/font/([%w]+)")
    return hash
end

-- 本地缓存路径
function Font.cache_path(hash)
    return font_dir() .. "/" .. hash .. ".ttf"
end

-- 字体家族名（crengine 显示名）
function Font.family_name(hash)
    return "ln_" .. hash
end

-- 是否已缓存
function Font.is_cached(hash)
    if not hash then return false end
    local ok = lfs.attributes(Font.cache_path(hash), "size")
    return ok and ok > 1000
end

--[[
下载并缓存字体。

参数：
  api     : lightnovel.api 模块（用于带鉴权的 GET，或直接用 http）
  font_path: 服务端返回的 Font 字段，如 "/font/cb29a534....woff2"
  base_url : API 基址

返回：本地 ttf 路径 或 nil, err
]]
function Font.ensure(api, font_path, base_url)
    local hash = Font.hash_from_path(font_path)
    if not hash then
        return nil, "invalid font path: " .. tostring(font_path)
    end

    local path = Font.cache_path(hash)
    if Font.is_cached(hash) then
        return path
    end

    ensure_dir(font_dir())

    base_url = (base_url or require("lightnovel.info").default_server):gsub("/+$", "")

    -- 优先 ttf：crengine 不支持 woff2，且服务端直接提供未压缩 ttf
    local urls = {
        base_url .. "/font/" .. hash .. ".ttf",
        base_url .. "/font/" .. hash .. ".woff2",
    }

    local last_err
    for _, url in ipairs(urls) do
        local body, err = api.download(url, { timeout = 90 })
        if body and #body > 1000 then
            -- woff2 不是 crengine 能用的格式，拒绝保存
            if url:match("%.woff2$") then
                last_err = "server only returned woff2 (unsupported by crengine)"
            else
                local f = io.open(path, "wb")
                if not f then
                    return nil, "cannot write " .. path
                end
                f:write(body)
                f:close()
                logger.info("font cached:", hash, #body, "bytes")
                return path
            end
        else
            last_err = err or ("http empty: " .. url)
        end
    end

    return nil, last_err or "font download failed"
end

-- 清理旧字体（保留最近 n 个，避免占满存储）
function Font.cleanup(keep)
    keep = keep or 5
    local dir = font_dir()
    if not lfs.attributes(dir) then return end
    local list = {}
    for entry in lfs.dir(dir) do
        if entry:match("%.ttf$") then
            local p = dir .. "/" .. entry
            local attr = lfs.attributes(p)
            list[#list + 1] = { path = p, mtime = attr and attr.modification or 0 }
        end
    end
    table.sort(list, function(a, b) return a.mtime > b.mtime end)
    for i = keep + 1, #list do
        os.remove(list[i].path)
    end
end

--[[
生成注入到章节 HTML 的 CSS 片段。

crengine 不解析 @font-face 的 src url()，它只认「已注册到字体列表里的 family 名」。
因此这里的做法是：
  1. 把 ttf 放到 koreader/fonts/lightnovel/ 下（crengine 会自动扫描）
  2. CSS 里直接用 family 名

family 名的确定：crengine 优先读 name 表；轻书架字体 name 表为空，
此时多数固件会退化为使用文件名（不含扩展名）。故文件命名为安全 ASCII。
]]
function Font.css(hash)
    local family = Font.family_name(hash)
    -- 同时覆盖常见容器，并提高优先级保证压过阅读器的用户字体设置
    return string.format(
        "html,body,.read,p,div,span,li,h1,h2,h3,h4,h5,h6{font-family:'%s' !important;}",
        family)
end

-- KOReader 全局字体目录（crengine 启动时扫描）
-- 注意：运行时新增字体通常需要重建字体列表，见 register() 的说明。
function Font.system_font_dir()
    local data_dir = require("datastorage").getDataDir()
    -- <koreader>/fonts
    return data_dir:gsub("/data$/", "") .. "/fonts/lightnovel"
end

--[[
把已缓存的字体注册到 KOReader（复制到 fonts 目录 + 触发字体列表重建）。

注意：crengine 的字体列表在启动时构建。运行时新增字体后，
KOReader 提供 `cre.getFontFaces()` 重扫；若固件不支持，
需要重启 KOReader 才能生效——这点已写进 README 的「已知限制」。
]]
function Font.register(hash)
    local src = Font.cache_path(hash)
    if not lfs.attributes(src, "size") then
        return nil, "字体未缓存: " .. tostring(hash)
    end

    local dir = Font.system_font_dir()
    ensure_dir(dir)
    local dst = dir .. "/" .. Font.family_name(hash) .. ".ttf"

    if not lfs.attributes(dst, "size") then
        local inf = io.open(src, "rb")
        if not inf then return nil, "无法读取缓存字体" end
        local data = inf:read("*a")
        inf:close()
        local outf = io.open(dst, "wb")
        if not outf then return nil, "无法写入 " .. dst end
        outf:write(data)
        outf:close()
        logger.info("font registered:", dst)
    end

    -- 尝试触发字体列表重扫（不同固件能力不一）
    pcall(function()
        local cre = require("libs/libkoreader-cre")
        if cre and cre.getFontFaces then
            cre.getFontFaces(true)
        end
    end)

    return dst
end

return Font
