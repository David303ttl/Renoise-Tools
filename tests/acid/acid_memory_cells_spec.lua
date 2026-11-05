dofile("tests/bootstrap.lua")("acid")

local memory_cells=require("views.memory_cells")
local CELL_WIDTH=40
local CELL_HEIGHT=20
local REFERENCE_HEIGHT=6
local PRIMARY_BORDER=2
local RELATED_BORDER=1
local UI_SCALE=1.5
local builder={}
setmetatable(builder,{__index=function(_,kind)
  return function(_,properties)
    local node={kind=kind,views={}}
    for key,value in pairs(properties or {}) do
      if type(key)=="number" then node.views[#node.views+1]=value
      else node[key]=value end
    end
    function node:add_view(child) self.views[#self.views+1]=child end
    function node:update()
      local context={size={width=self.size.width*UI_SCALE,height=self.size.height*UI_SCALE},
        pixel_size={width=self.size.width*UI_SCALE,height=self.size.height*UI_SCALE},
        stroke_rect=function(context,x,y,width,height)
          context.stroke={x=x,y=y,width=width,height=height,line_width=context.line_width,
            color=context.stroke_color}
        end}
      self.last_context=context
      self.render(context)
    end
    return node
  end
end})

local cells=memory_cells.new(builder)
local button={}
local reference={height=REFERENCE_HEIGHT}
local wrapped=cells.wrap("cell",button,CELL_WIDTH,CELL_HEIGHT,reference)
local canvas=wrapped.views[1]
local CANVAS_HEIGHT=CELL_HEIGHT+REFERENCE_HEIGHT
assert(canvas.size.width==CELL_WIDTH and canvas.size.height==CANVAS_HEIGHT and
  reference.width==CELL_WIDTH-PRIMARY_BORDER*2,
  "reference row contributes to the final canvas geometry")
local function assert_outline(selection,border,color)
  cells.select(button,selection)
  canvas:update()
  local stroke=canvas.last_context.stroke
  assert(stroke and stroke.x==border/2 and stroke.y==border/2 and
    stroke.width==CELL_WIDTH-border and stroke.height==CANVAS_HEIGHT-border and
    stroke.line_width==border and stroke.color[1]==color[1] and
    stroke.color[2]==color[2] and stroke.color[3]==color[3],
    string.format("%s outline geometry: %s",selection,
      stroke and string.format("x=%s y=%s w=%s h=%s line=%s",
        tostring(stroke.x),tostring(stroke.y),tostring(stroke.width),
        tostring(stroke.height),tostring(stroke.line_width)) or "not drawn"))
end

assert_outline("primary",PRIMARY_BORDER,{0xF2,0xC5,0x46})
assert_outline("related",RELATED_BORDER,{0xA8,0x8D,0x4C})
cells.select(button,nil)
canvas:update()
assert(canvas.last_context.stroke==nil,"clearing the role removes the outline")
assert(not pcall(function()cells.select(button,true)end),
  "selection requires an explicit primary or related role")
print("ACID memory cell selection roles and scaled geometry checks passed")
