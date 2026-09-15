--[[
轻书架 KOReader 插件 —— 状态与配置持久化

负责保存：
  - Token / RefreshToken（登录态）
  - 服务器线路
  - 书架内存缓存 + 文件缓存
  - 目录缓存
  - 阅读设置

采用「内存主源 + 文件后备」两级缓存策略，适配弱性能墨水屏设备。
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local Log = require("lightnovel.logger")

local State = {}

local settings_dir = DataStorage:getSettingsDir() .. "/lightnovel"
local auth_file = settings_dir .. "/auth.json"
local config_file = settings_dir .. "/config.json"
local shelf_cache_file = settings_dir .. "/shelf_cache.json"
local dir_cache_prefix = settings_dir .. "/dir_cache_"

-- 书架缓存 TTL（秒）
local SHELF_TTL = 5 * 60
-- 目录缓存 TTL（秒）
local DIR_TTL = 24 * 60 * 60

local state = {
    -- 鉴权
    token = "",
    refresh_token = "",
    token_time = 0,
    email = "",
    user_name = "",

    -- 配置
    server = "https://api.lightnovel.life",
    pre_download_chapters = 3,
    download_book_images = true,
    pull_on_open = true,
    upload_on_close = true,
    log_level = "warn",

    -- 运行时缓存（内存主源）
    shelf_mem_cache = nil,        -- { data = {...}, time = ts }
    dir_mem_cache = {},           -- [book_id] = { data = {...}, time = ts }

    -- 最近打开的书籍（用于快速测试）
    last_book = nil,
}

function State:ensure_dir()
    if not lfs.attributes(settings_dir, "mode") then
        lfs.mkdir(settings_dir)
    end
    -- lfs.mkdir 不会递归创建父目录，确保 settings 目录存在
    local parent = DataStorage:getSettingsDir()
    if not lfs.attributes(parent, "mode") then
        lfs.mkdir(parent)
    end
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(rapidjson.decode, content)
    if not ok then
        Log.warn("解析 JSON 失败: %s", path)
        return nil
    end
    return data
end

local function write_json(path, data)
    State:ensure_dir()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        Log.warn("无法写入文件: %s", path)
        return false
    end
    local ok, encoded = pcall(rapidjson.encode, data)
    if not ok then
        f:close()
        os.remove(tmp)
        Log.warn("序列化 JSON 失败: %s", path)
        return false
    end
    f:write(encoded)
    f:close()
    -- 原子替换，避免写一半掉电导致缓存损坏
    os.remove(path)
    os.rename(tmp, path)
    return true
end

-- ============ 初始化 ============

function State:init()
    self:ensure_dir()

    local auth = read_json(auth_file)
    if auth then
        state.token = auth.token or ""
        state.refresh_token = auth.refresh_token or ""
        state.token_time = auth.token_time or 0
        state.email = auth.email or ""
        state.user_name = auth.user_name or ""
    end

    local config = read_json(config_file)
    if config then
        state.server = config.server or state.server
        state.pre_download_chapters = config.pre_download_chapters or state.pre_download_chapters
        state.download_book_images = config.download_book_images ~= false
        state.pull_on_open = config.pull_on_open ~= false
        state.upload_on_close = config.upload_on_close ~= false
        state.log_level = config.log_level or state.log_level
    end

    Log.set_level(state.log_level)
    Log.info("状态初始化完成，服务器: %s", state.server)
end

-- ============ 鉴权 ============

function State:save_auth(token, refresh_token, email, user_name)
    state.token = token or ""
    state.refresh_token = refresh_token or ""
    state.token_time = os.time()
    if email then state.email = email end
    if user_name then state.user_name = user_name end

    write_json(auth_file, {
        token = state.token,
        refresh_token = state.refresh_token,
        token_time = state.token_time,
        email = state.email,
        user_name = state.user_name,
    })
end

function State:clear_auth()
    state.token = ""
    state.refresh_token = ""
    state.token_time = 0
    state.user_name = ""
    write_json(auth_file, { token = "", refresh_token = "", token_time = 0, email = state.email, user_name = "" })
end

function State:get_token() return state.token end
function State:get_refresh_token() return state.refresh_token end
function State:is_logged_in() return state.token ~= "" end
function State:get_email() return state.email end
function State:get_user_name() return state.user_name end

-- ============ 配置 ============

function State:save_config()
    write_json(config_file, {
        server = state.server,
        pre_download_chapters = state.pre_download_chapters,
        download_book_images = state.download_book_images,
        pull_on_open = state.pull_on_open,
        upload_on_close = state.upload_on_close,
        log_level = state.log_level,
    })
end

function State:get_server() return state.server end
function State:set_server(url)
    state.server = url
    self:save_config()
end

function State:get_pre_download() return state.pre_download_chapters end
function State:set_pre_download(n)
    state.pre_download_chapters = n
    self:save_config()
end

function State:get_download_images() return state.download_book_images end
function State:set_download_images(v)
    state.download_book_images = v
    self:save_config()
end

function State:get_pull_on_open() return state.pull_on_open end
function State:set_pull_on_open(v)
    state.pull_on_open = v
    self:save_config()
end

function State:get_upload_on_close() return state.upload_on_close end
function State:set_upload_on_close(v)
    state.upload_on_close = v
    self:save_config()
end

function State:set_log_level(level)
    state.log_level = level
    Log.set_level(level)
    self:save_config()
end
function State:get_log_level() return state.log_level end

-- ============ 最近打开的书籍 ============

function State:get_last_book() return state.last_book end

function State:set_last_book(id)
    state.last_book = tonumber(id) or id
    self:save_config()
end

-- ============ 书架缓存（内存主源 + 文件后备）============

function State:get_shelf_cache(max_age)
    local ttl = max_age or SHELF_TTL
    local mem = state.shelf_mem_cache
    if mem and (os.time() - mem.time) < ttl then
        -- 返回浅拷贝，避免调用方排序污染原始顺序
        local copy = {}
        for i, v in ipairs(mem.data) do copy[i] = v end
        return copy
    end

    -- 内存未命中，回退文件缓存
    local file_cache = read_json(shelf_cache_file)
    if file_cache and file_cache.data and (os.time() - (file_cache.time or 0)) < ttl then
        state.shelf_mem_cache = file_cache
        local copy = {}
        for i, v in ipairs(file_cache.data) do copy[i] = v end
        return copy
    end
    return nil
end

-- 无论新旧都返回（离线兜底用）
function State:get_shelf_cache_any_age()
    if state.shelf_mem_cache and state.shelf_mem_cache.data then
        local copy = {}
        for i, v in ipairs(state.shelf_mem_cache.data) do copy[i] = v end
        return copy
    end
    local file_cache = read_json(shelf_cache_file)
    if file_cache and file_cache.data then
        state.shelf_mem_cache = file_cache
        local copy = {}
        for i, v in ipairs(file_cache.data) do copy[i] = v end
        return copy
    end
    return nil
end

function State:set_shelf_cache(data)
    local entry = { data = data, time = os.time() }
    state.shelf_mem_cache = entry
    write_json(shelf_cache_file, entry)
end

function State:clear_shelf_cache()
    state.shelf_mem_cache = nil
    os.remove(shelf_cache_file)
end

-- ============ 目录缓存 ============

local function dir_cache_path(book_id)
    return dir_cache_prefix .. tostring(book_id) .. ".json"
end

function State:get_dir_cache(book_id)
    local mem = state.dir_mem_cache[book_id]
    if mem and (os.time() - mem.time) < DIR_TTL then
        local copy = {}
        for i, v in ipairs(mem.data) do copy[i] = v end
        return copy
    end

    local file_cache = read_json(dir_cache_path(book_id))
    if file_cache and file_cache.data and (os.time() - (file_cache.time or 0)) < DIR_TTL then
        state.dir_mem_cache[book_id] = file_cache
        local copy = {}
        for i, v in ipairs(file_cache.data) do copy[i] = v end
        return copy
    end
    return nil
end

function State:get_dir_cache_any_age(book_id)
    local mem = state.dir_mem_cache[book_id]
    if mem and mem.data then
        local copy = {}
        for i, v in ipairs(mem.data) do copy[i] = v end
        return copy
    end
    local file_cache = read_json(dir_cache_path(book_id))
    if file_cache and file_cache.data then
        state.dir_mem_cache[book_id] = file_cache
        local copy = {}
        for i, v in ipairs(file_cache.data) do copy[i] = v end
        return copy
    end
    return nil
end

function State:set_dir_cache(book_id, data)
    local entry = { data = data, time = os.time() }
    state.dir_mem_cache[book_id] = entry
    write_json(dir_cache_path(book_id), entry)
end

function State:clear_dir_cache(book_id)
    state.dir_mem_cache[book_id] = nil
    os.remove(dir_cache_path(book_id))
end

-- ============ 清理 ============

function State:clear_all()
    self:clear_shelf_cache()
    for book_id, _ in pairs(state.dir_mem_cache) do
        os.remove(dir_cache_path(book_id))
    end
    state.dir_mem_cache = {}
    Log.info("已清空全部缓存")
end

return State
