local _ = require("gettext")

-- 版本信息集中于 info.lua，避免多处维护不同步
local ok_info, info = pcall(require, "lightnovel.info")
local version = (ok_info and info and info.version) or "0.1.0"
local description = (ok_info and info and info.description)
    or _("在 KOReader 中阅读轻书架（lightnovel.app）小说，支持邮箱登录、书架同步、章节阅读、离线缓存，适配墨水屏黑白显示。")

return {
    name = "lightnovel",
    fullname = _("轻书架"),
    description = description,
    version = version,
}
