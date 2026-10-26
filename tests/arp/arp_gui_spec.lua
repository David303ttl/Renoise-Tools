dofile('tests/bootstrap.lua')('arp')
-- Regression test for Song __eq crash in ARP GUI.
local calls=0
local button_callback, status, new_document
package.loaded.pattern_writer={
  track_choices=function() return {"Track 1","Track 2"},{1,2} end,
  generate=function(source,dest)
    calls=calls+1
    assert(source==1 and dest==2)
    return {action="Generated",notes=4,offs=4,columns=1}
  end
}
local song=setmetatable({selected_track_index=1,selected_instrument_index=1,instruments={{name="Bass"}}},
  {__eq=function() error("Renoise Song equality is unsupported") end})
local last_dialog
renoise={
  tool=function() return {app_new_document_observable={
    add_notifier=function(_,callback) new_document=callback end
  }} end,
  song=function() return song end,
  app=function() return {
    show_warning=function(_,msg) error(msg) end,
    show_custom_dialog=function()
      local d={visible=true,closed=false,
        show=function(self) self.visible=true end,
        close=function(self) self.visible=false;self.closed=true end}
      last_dialog=d
      return d
    end
  } end,
  ViewBuilder=function()
    local b={}
    for _,kind in ipairs({"text","popup","column","row","button","checkbox"}) do
      b[kind]=function(_,obj)
        if kind=="button" then button_callback=obj.notifier end
        if kind=="text" and obj.width==455 then status=obj end
        return obj
      end
    end
    return b
  end
}
local gui=require("gui")
gui.show()
assert(button_callback and new_document)
button_callback()
assert(calls==1 and status.text=="Generated 4 notes, 4 note-offs in 1 column.")
new_document()
button_callback()
assert(calls==1 and status.text=="Song changed. Close and reopen ARP.")
local prior=last_dialog
song=setmetatable({selected_track_index=1,selected_instrument_index=1,instruments={{name="Bass"}}},
  {__eq=function() error("Renoise Song equality is unsupported") end})
gui.show()
assert(prior.closed and last_dialog~=prior)
button_callback()
assert(calls==2)
print("ARP GUI document-change regression test passed")
