-- SPDX-License-Identifier: GPL-3.0-only
-- Native controls retain their event colors beneath a separate selection frame.
local M = {}
local BORDER = 2
local AMBER = {0xF2,0xC5,0x46}

function M.new(vb)
  local frames = {}
  local cells = {}
  function cells.wrap(id,button,width,height,reference)
    local frame = {selected=false}
    local content = vb:column{margin=BORDER,spacing=0,button}
    button.size={width=width-BORDER*2,height=height-BORDER*2}
    if reference then
      reference.width=width-BORDER*2
      content:add_view(reference)
      height=height+reference.height
    end
    frame.canvas=vb:canvas{id=id.."_selection",size={width=width,height=height},render=function(context)
      if frame.selected then
        context.stroke_color=AMBER
        context.line_width=BORDER
        context:stroke_rect(BORDER/2,BORDER/2,
          context.size.width-BORDER,context.size.height-BORDER)
      end
    end}
    frames[button]=frame
    return vb:stack{size={width=width,height=height},frame.canvas,content}
  end
  function cells.select(button,selected)
    local frame=assert(frames[button])
    if frame.selected~=selected then
      frame.selected=selected
      frame.canvas:update()
    end
  end
  return cells
end

return M
