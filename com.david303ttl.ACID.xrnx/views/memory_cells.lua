-- SPDX-License-Identifier: GPL-3.0-only
-- Native controls retain their event colors beneath a separate selection frame.
local M = {}
local PRIMARY_BORDER = 2
local RELATED_BORDER = 1
local PRIMARY_AMBER = {0xF2,0xC5,0x46}
local RELATED_AMBER = {0xA8,0x8D,0x4C}

function M.new(vb)
  local frames = {}
  local cells = {}
  function cells.wrap(id,button,width,height,reference)
    local frame = {selection=nil}
    local content = vb:column{margin=PRIMARY_BORDER,spacing=0,button}
    button.size={width=width-PRIMARY_BORDER*2,height=height-PRIMARY_BORDER*2}
    if reference then
      reference.width=width-PRIMARY_BORDER*2
      content:add_view(reference)
      height=height+reference.height
    end
    local canvas_width,canvas_height=width,height
    frame.canvas=vb:canvas{id=id.."_selection",size={width=width,height=height},render=function(context)
      if frame.selection then
        local border=frame.selection=="primary" and PRIMARY_BORDER or RELATED_BORDER
        context.stroke_color=frame.selection=="primary" and PRIMARY_AMBER or RELATED_AMBER
        context.line_width=border
        context:stroke_rect(border/2,border/2,
          canvas_width-border,canvas_height-border)
      end
    end}
    frames[button]=frame
    return vb:stack{size={width=width,height=height},frame.canvas,content}
  end
  function cells.select(button,selection)
    local frame=assert(frames[button])
    assert(selection==nil or selection=="primary" or selection=="related",
      "invalid selection role")
    if frame.selection~=selection then
      frame.selection=selection
      frame.canvas:update()
    end
  end
  return cells
end

return M
