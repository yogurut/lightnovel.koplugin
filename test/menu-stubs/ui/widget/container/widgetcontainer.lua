local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer
function WidgetContainer:extend(sub)
    sub = sub or {}
    sub.__index = sub
    sub.new = function(cls, o)
        o = o or {}
        setmetatable(o, cls)
        if cls.init then cls.init(o) end
        return o
    end
    return setmetatable(sub, { __index = WidgetContainer, __call = function(c, o) return c.new(c, o) end })
end
function WidgetContainer.init(self) self._wc_inited = true end
return WidgetContainer
