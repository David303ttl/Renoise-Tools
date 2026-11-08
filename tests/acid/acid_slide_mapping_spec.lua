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
    assert(selection.primary and selection.related and selection.pitches==nil and selection.times==nil)
    assert(selection.related.pitches[memory=="pitch" and (index==1 and 2 or 1) or
      (index==3 and 1 or 2)])
    assert(selection.related.times[1] or selection.primary.times[1])
    assert(selection.related.times[2] or selection.primary.times[2])
    assert(selection.related.times[3] or selection.primary.times[3])
    assert(not selection.related.times[4] and not selection.primary.times[4])
    if memory=="pitch" then
      assert(selection.primary.pitches[index] and not selection.primary.times[index])
    else
      local event=projection.mapping[index]
      assert(selection.primary.times[index] and selection.primary.pitches[event.pitch_index])
      assert(not selection.related.times[index])
    end
    assert(#selection.descriptions==1)
  end
end
local unrelated=editor.slide_selection(projection,"time",4,false)
assert(#unrelated.descriptions==0 and unrelated.primary.times[4] and
  not unrelated.primary.pitches[1] and not unrelated.related.pitches[1])

local plain=seq.new_pattern(2)
plain.pitch_length=2
plain.pitch_events[2]=seq.new_pitch(5,0)
local plain_projection=editor.project(plain)
local plain_selection=editor.slide_selection(plain_projection,"pitch",1,false)
assert(#plain_projection.slides==0 and plain_selection.primary.pitches[1] and
  plain_selection.related.times[1] and not plain_selection.related.times[2],
  "a selected PITCH relates its mapped TIME step without a slide")

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
local seam_selection=editor.slide_selection(seam,"time",1,true)
assert(seam_selection.related.times[4] and seam_selection.primary.times[1])

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
assert(selected.related.times[15] and selected.related.times[16] and selected.related.times[17] and
  selected.primary.times[18],
  "a slide can cross a TIME page with held steps")
source.time_events[1]=nil
local incomplete=editor.project(source)
assert(incomplete.error and #incomplete.slides==0)
assert(editor.time_reference(incomplete,1,false,true)=="--")
assert(editor.slide_block_reason(incomplete,1,true)=="Slide: mapping unavailable")
print("ACID slide mapping, holds, rests, wrapping and repeat-boundary checks passed")
