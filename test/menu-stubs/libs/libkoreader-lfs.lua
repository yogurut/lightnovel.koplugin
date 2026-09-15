local lfs = {}
lfs.attributes = function(p, f)
  local h = io.open(p, "r")
  if h then h:close() return f == "mode" and "file" or 1 end
  -- 目录探测
  local ok = os.execute("test -d '"..p.."' 2>/dev/null")
  if ok == 0 or ok == true then return f == "mode" and "directory" or 0 end
  return nil
end
lfs.mkdir = function(p) os.execute("mkdir -p '"..p.."'") return true end
lfs.dir = function(p) return function() return nil end end
return lfs
