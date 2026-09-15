--[[
轻书架 KOReader 插件 —— 日志工具

统一日志输出，支持级别过滤与写入文件，方便在设备上排查问题。
]]

local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local logger = require("logger")

local Log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

local log_file = nil
local min_level = LEVELS.warn

local function get_log_path()
    if not log_file then
        log_file = DataStorage:getSettingsDir() .. "/lightnovel.log"
    end
    return log_file
end

function Log.set_level(level)
    min_level = LEVELS[level] or LEVELS.warn
end

local function write(level, fmt, ...)
    local lv = LEVELS[level] or LEVELS.info
    if lv < min_level then return end

    local msg
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end

    local line = string.format("[lightnovel][%s] %s", level:upper(), msg)

    if level == "error" then
        logger.err(line)
    elseif level == "warn" then
        logger.warn(line)
    else
        logger.info(line)
    end

    -- 追加写入日志文件（失败静默，不影响主流程）
    local f = io.open(get_log_path(), "a")
    if f then
        local ts = os.date("%Y-%m-%d %H:%M:%S")
        f:write(string.format("[%s] %s\n", ts, line))
        f:close()
    end
end

function Log.debug(fmt, ...) write("debug", fmt, ...) end
function Log.info(fmt, ...)  write("info", fmt, ...) end
function Log.warn(fmt, ...)  write("warn", fmt, ...) end
function Log.error(fmt, ...) write("error", fmt, ...) end

function Log.get_path() return get_log_path() end

return Log
