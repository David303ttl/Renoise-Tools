dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local editor=require("model.editor_state")

local source=seq.new_pattern(4)
source.pitch_length=3
source.pitch_events[1]=seq.new_pitch(4,-1,false,true)
source.pitch_events[2]=seq.new_pitch(4,1)
source.time_events[2]="T"
local projection=editor.project(source)
assert(not projection.error and #projection.slides==1)
local link=projection.slides[1]
assert(link.from_step==1 and link.from_pitch==1 and link.from_note==28)
assert(link.to_step==3 and link.to_pitch==2 and link.to_note==52)
assert(not link.next_cycle and link.times[1] and link.times[2] and link.times[3] and not link.times[4])
assert(editor.slide_text(link)=="Slide: T01 / P01 E2 → T03 / P02 E4 · via T02")
assert(editor.time_reference(projection,1,false,false)=="P01 →")
assert(editor.time_reference(projection,2,false,false)=="P01 hold →")
assert(editor.time_reference(projection,3,true,false)=="↗ P02 · E4")
assert(editor.slide_marker(projection,1,false)=="SLD→")
for _,memory in ipairs({"pitch","time"}) do
  local indices=memory=="pitch" and {1,2} or {1,2,3}
  for _,index in ipairs(indices) do
    local selection=editor.slide_selection(projection,memory,index,false)
    assert(selection.pitches[1] and selection.pitches[2] and not selection.pitches[3])
    assert(selection.times[1] and selection.times[2] and selection.times[3] and not selection.times[4])
    assert(#selection.descriptions==1)
  end
end
assert(#editor.slide_selection(projection,"time",4,false).descriptions==0)

source.time_events[2]="R"
local blocked=editor.project(source)
assert(#blocked.slides==0 and editor.slide_marker(blocked,1,true)=="SLD")
assert(editor.slide_block_reason(blocked,1,true)=="Slide: blocked by T02 Rest")
assert(editor.time_reference(blocked,1,false,true)=="P01")
assert(editor.time_reference(blocked,3,false,true)=="P02")
assert(editor.slide_block_reason(blocked,4,true)=="Slide: unused pitch")
assert(#projection.slides==1,"later source edits must not rewrite the projection")

source=seq.new_pattern(4)
source.pitch_length=2
source.time_events[3]="T"
source.time_events[4]="T"
source.pitch_events[2]=seq.new_pitch(7,0,false,true)
local seam=editor.project(source)
assert(#seam.slides==1 and seam.slides[1].next_cycle)
assert(editor.slide_text(seam.slides[1])==
  "Slide: T02 / P02 G3 → next cycle T01 / P01 C3 · via T03–T04")
assert(editor.time_reference(seam,1,false,true)=="↗↻ P01")
assert(editor.time_reference(seam,2,false,true)=="P02 →↻")
assert(editor.time_reference(seam,4,false,true)=="P02 hold →↻")
assert(editor.time_reference(seam,1,false,false)=="P01")
assert(editor.time_reference(seam,2,false,false)=="P02")
assert(#editor.slide_selection(seam,"time",1,false).descriptions==0)
assert(editor.slide_block_reason(seam,2,false)=="Slide: ends at pattern boundary")
assert(editor.slide_selection(seam,"time",1,true).times[4])

source=seq.new_pattern(1)
source.pitch_length=1
source.pitch_events[1]=seq.new_pitch(0,0,false,true)
local self_slide=editor.project(source)
assert(#self_slide.slides==1 and self_slide.slides[1].next_cycle)
assert(editor.time_reference(self_slide,1,false,true)=="↗↻ P01 →↻")
assert(editor.time_reference(self_slide,1,false,false)=="P01")

source=seq.new_pattern(32)
source.pitch_length=2
source.pitch_events[1]=seq.new_pitch(3,0,false,true)
source.time_events[16]="T"
source.time_events[17]="T"
local paged=editor.project(source)
local selected=editor.slide_selection(paged,"time",18,false)
assert(selected.times[15] and selected.times[16] and selected.times[17] and selected.times[18],
  "a slide can cross a TIME page with held steps")
source.time_events[1]=nil
local incomplete=editor.project(source)
assert(incomplete.error and #incomplete.slides==0)
assert(editor.time_reference(incomplete,1,false,true)=="--")
assert(editor.slide_block_reason(incomplete,1,true)=="Slide: mapping unavailable")
print("ACID slide mapping, holds, rests, wrapping and repeat-boundary checks passed")
