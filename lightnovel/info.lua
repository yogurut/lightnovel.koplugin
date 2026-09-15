--[[
轻书架 KOReader 插件 —— 常量与版本信息
]]

local _ = require("gettext")

return {
    name = "lightnovel",
    fullname = _("轻书架"),
    version = "0.1.1",
    description = _("在 KOReader 中阅读轻书架（lightnovel.app）小说，支持邮箱登录、章节阅读、字体解密还原、离线缓存，适配墨水屏黑白显示。"),

    -- 服务器地址（可在设置中切换备用线路）
    default_server = "https://api.lightnovel.life",
    servers = {
        { label = "主线路 (api)",        value = "https://api.lightnovel.life" },
        { label = "Cloudflare (cf-api)", value = "https://cf-api.lightnovel.life" },
    },

    -- Hub 路径（SignalR）
    hub_path = "/hub/api",

    -- 默认分页大小
    default_page_size = 24,

    -- 默认预下载章节数
    default_pre_download = 3,
}
