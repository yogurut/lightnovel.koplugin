-- KOReader 的 WidgetContainer 模块桩（忠实反映真实实现）
--
-- 重要：真实的 WidgetContainer 是一个**空基类**，没有 init 方法。
-- 之前这个桩里凭空加了一个 WidgetContainer.init，把
-- “main.lua 调用了 WidgetContainer.init(self)” 这个 bug 掩盖了，
-- 结果真机上直接报 “attempt to call field 'init' (a nil value)”。
-- 现在故意不提供 init，让测试能复现真机行为。

local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer

function WidgetContainer:extend(sub)
    sub = sub or {}
    sub.__index = sub
    sub.new = function(cls, o)
        o = o or {}
        setmetatable(o, cls)
        -- KOReader 的 WidgetContainer:new 会调用 init（如果子类定义了）
        if cls.init then
            cls.init(o)
        end
        return o
    end
    return setmetatable(sub, {
        __index = WidgetContainer,
        __call = function(c, o) return c.new(c, o) end,
    })
end

-- 故意不定义 WidgetContainer.init —— 真实实现里就没有。

return WidgetContainer
