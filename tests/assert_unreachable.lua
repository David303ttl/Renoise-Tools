-- Inspect retained tables, keys, metatables and closure upvalues by raw identity.
return function(roots,forbidden)
  collectgarbage('collect');collectgarbage('collect')
  local labels,seen={},{}
  for label,object in pairs(forbidden)do labels[object]=label end
  local function visit(value,path)
    local label=labels[value]
    if label then error(path..' retains '..label,0)end
    local kind=type(value)
    if (kind~='table' and kind~='function')or seen[value]then return end
    seen[value]=true
    if kind=='table'then
      for key,child in pairs(value)do
        visit(key,path..'.key');visit(child,path..'.'..tostring(key))
      end
      local mt=getmetatable(value)
      if type(mt)=='table'then visit(mt,path..'.metatable')end
    else
      local index=1
      while true do
        local name,child=debug.getupvalue(value,index)
        if not name then break end
        if name~='_ENV'then visit(child,path..'.upvalue:'..name)end
        index=index+1
      end
    end
  end
  visit(roots,'retained')
end
