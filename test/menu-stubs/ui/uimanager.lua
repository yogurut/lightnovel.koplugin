return {
  show = function(self, w) end,
  close = function(self, w) end,
  nextTick = function(self, f) f() end,
  getWidth = function() return 600 end,
  getHeight = function() return 800 end,
}
