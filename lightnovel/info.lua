--[[
轻书架 KOReader 插件 —— 常量与版本信息
]]

local _ = require("gettext")

return {
    name = "lightnovel",
    fullname = _("轻书架"),
    version = "0.1.2",
    description = _("在 KOReader 中阅读轻书架（lightnovel.app）小说，支持邮箱登录、章节阅读、字体解密还原、离线缓存，适配墨水屏黑白显示。"),

    -- 服务器地址（可在设置中切换，也可自动择优）
    --
    -- 注意：只有下面这两个是真正的 API 域名。
    -- 前端站点（www.lightnovel.app / www.lightnovel.life /
    -- www.lightnovel.love / www.acgdmzy.com）只是套壳入口，
    -- 它们的 /api/ 与 /hub/ 都不会转发到后端（返回 405 路由兑底），
    -- 所以不能当作 API 基址。
    --
    -- 来源：前端 assets/apiServer-*.js 中的官方配置
    --   [{label:"hk", value:"https://api.lightnovel.life"},
    --    {label:"cloudflare", value:"https://cf-api.lightnovel.life"}]
    default_server = "https://api.lightnovel.life",
    servers = {
        { label = "香港线路 (hk/api)",  value = "https://api.lightnovel.life" },
        { label = "Cloudflare (cf-api)", value = "https://cf-api.lightnovel.life" },
    },

    -- Hub 路径（SignalR）
    hub_path = "/hub/api",

    -- 默认分页大小
    default_page_size = 24,

    -- 默认预下载章节数
    default_pre_download = 3,
}
