dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local editor=require("model.editor_state")
local interpreter=require("model.cycle_interpreter")
local pattrns=require("writers.pattrns_writer")

assert(editor.MAX_PAGES==seq.MAX_STEPS/seq.PAGE_SIZE)
for index=1,seq.MAX_STEPS do
  local page=editor.page_for(index)
  local cell=(index-1)%seq.PAGE_SIZE+1
  assert(editor.index_on_page(page,cell)==index)
end
for _,invalid in ipairs({0,seq.MAX_STEPS+1,1.5,0/0}) do
  assert(not pcall(editor.page_for,invalid))
end
assert(not pcall(editor.index_on_page,editor.MAX_PAGES+1,1))
assert(not pcall(editor.index_on_page,1,seq.PAGE_SIZE+1))

local history_source=seq.new_pattern(16)
local history=editor.new_history(history_source,"repeat",0)
history_source.pitch_events[1]=seq.new_pitch(4,1,true,true)
history:record(history_source,"play_once",12)
history_source.time_events[2]="R"
history:record(history_source,"play_once",12)
assert(not history:record(history_source,"play_once",12),
  "unchanged source and render settings do not add history")
assert(history:record(history_source,"play_once",24),
  "a PB range change is an undoable state change")
local undone,policy,pb_range=history:undo()
assert(undone.time_events[2]=="R" and undone.pitch_events[1].note==52)
assert(policy=="play_once" and pb_range==12)
undone,policy,pb_range=history:undo()
assert(undone.time_events[2]=="N" and undone.pitch_events[1].note==52 and
  policy=="play_once" and pb_range==12)
undone,policy,pb_range=history:undo()
assert(undone.pitch_events[1].note==36 and policy=="repeat" and pb_range==0)
local redone
redone,policy,pb_range=history:redo()
assert(redone.pitch_events[1].note==52 and policy=="play_once" and pb_range==12)
redone,policy,pb_range=history:redo()
assert(redone.time_events[2]=="R" and policy=="play_once" and pb_range==12)
redone,policy,pb_range=history:redo()
assert(redone.time_events[2]=="R" and policy=="play_once" and pb_range==24)
history_source=assert(history:undo())
history_source.time_events[3]="T"
history:record(history_source,"repeat",48)
assert(not history:can_redo())
local branched=assert(history:undo())
assert(branched.time_events[3]=="N")
assert(not pcall(editor.new_history,history_source,"repeat",4))
assert(not pcall(function()history:record(history_source,"repeat",4)end))

-- A newly initialized 16-step pattern needs no manual PITCH entry.
local fresh=seq.new_pattern(16)
assert(#fresh.pitch_events==32)
for i=1,16 do fresh.time_events[i]="N" end
local fresh_view=editor.project(fresh)
assert(not fresh_view.error and fresh_view.note_count==16)
for i=1,16 do
  assert(fresh_view.mapping[i].pitch_index==i)
  assert(fresh_view.mapping[i].note==36)
  assert(not fresh_view.mapping[i].accent and not fresh_view.mapping[i].slide)
end
assert(interpreter.compile_cycle(fresh).steps[16].note==36)
local seam=seq.new_pattern(1)
seam.pitch_length=1
seam.pitch_events[1]=seq.new_pitch(0,0,false,true)
assert(seq.set_time(seam,1,"N")=="N")
local seam_view=editor.project(seam)
assert(seam_view.mapping[1].transition=="attack")
assert(seam_view.repeat_mapping[1].transition=="slide")
assert(editor.step_text(seam_view,1,1):find("A",1,true))
assert(editor.step_text(seam_view,1,2):find("S",1,true))

for _,length in ipairs({1,16,17,31,32}) do
  local p=seq.new_pattern(length)
  assert(p.length==length)
  for i=1,length do p.time_events[i]=i%4==1 and "N" or i%4==2 and "T" or "R" end
  p.pitch_events[1]=seq.new_pitch(0,0,true,true)
  p.pitch_events[2]=seq.new_pitch(3,1)
  p.pitch_events[3]=seq.new_pitch(5,-1)
  p.pitch_length=3
  assert(seq.validate(p))
  local projection=editor.project(p)
  assert(not projection.error)
  assert(projection.note_count==math.floor((length+3)/4))
  local plan,err=interpreter.compile_cycle(p)
  assert(plan,err)
  local src,meta=pattrns.emit(plan)
  assert(src,meta)
  assert(meta.steps==length)
end
assert(not pcall(seq.new_pattern,33))
assert(editor.page_for(1)==1 and editor.page_for(17)==2)
assert(editor.page_for(32)==2)
assert(editor.index_on_page(2,16)==32)
assert(not pcall(editor.page_for,33) and not pcall(editor.index_on_page,3,1))
for _,octave in ipairs({-1,0,1}) do
  for key=0,12 do
    local p=seq.new_pitch(key,octave,true,false)
    local k,o=seq.pitch_controls(p)
    assert(k==key and o==octave)
    assert(p.note==36+key+12*octave)
    local single=seq.new_pattern(1)
    single.pitch_length=1
    single.pitch_events[1]=p
    for i,command in ipairs({"N"}) do single.time_events[i]=command end
    assert(seq.validate(single))
  end
end
local mismatched=seq.new_pitch(0,0)
mismatched.note=37
local mismatched_source=seq.new_pattern(1)
mismatched_source.pitch_length=1
mismatched_source.pitch_events[1]=mismatched
for i,command in ipairs({"N"}) do mismatched_source.time_events[i]=command end
local valid,diagnostic=seq.validate(mismatched_source)
assert(not valid)
assert(diagnostic=="pitch keyboard/octave does not match MIDI note at pitch entry 1")
local bad=seq.new_pattern(17)
bad.pitch_events[1]=seq.new_pitch(0,0)
bad.pitch_events[2]=seq.new_pitch(3,1)
bad.pitch_length=2
for i=1,17 do bad.time_events[i]="R" end
bad.time_events[16]="N"
bad.time_events[17]="T"
local preview=editor.project(bad)
assert(not preview.error)
assert(preview.mapping[16].pitch_index==1)
assert(preview.mapping[17].pitch_index==1)
assert(preview.mapping[17].kind=="tie")
assert(editor.step_text(preview,17)=="TIE P01")
bad.time_events[17]="N"
preview=editor.project(bad)
assert(preview.mapping[17].pitch_index==2)
bad.time_events[16]=nil
preview=editor.project(bad)
assert(preview.error and preview.error.step==16, preview.error and preview.error.message or "no error")
bad.time_events[16]="Q"
preview=editor.project(bad)
assert(preview.error and preview.error.step==16)
local off=seq.new_pattern(32)
off.pitch_events[1]=seq.new_pitch(0,0)
off.pitch_events[2]=seq.new_pitch(7,0)
off.pitch_length=2
for i=1,32 do off.time_events[i]=(i==1 or i==32) and "N" or "R" end
local plan=assert(interpreter.compile_cycle(off))
assert(plan.steps[32].pitch_index==2 and plan.note_count==2)
local timed=seq.new_pattern(32)
assert(timed.timing_mode=="straight")
timed.pitch_length=3
timed.pitch_events[32]=seq.new_pitch(11,1,true,true)
timed.time_events[32]="R"
local timing_history=editor.new_history(timed,"repeat",0)
local before=assert(interpreter.compile_cycle(timed))
timed.timing_mode="triplet"
assert(timing_history:record(timed,"repeat",0))
assert(not timing_history:record(timed,"repeat",0))
local after=assert(interpreter.compile_cycle(timed))
for i=1,32 do
  assert(before.steps[i].note==after.steps[i].note)
  assert(before.steps[i].pitch_index==after.steps[i].pitch_index)
end
local straight=timing_history:undo()
assert(straight.timing_mode=="straight" and not timing_history:can_undo())
local triplet=timing_history:redo()
assert(triplet.timing_mode=="triplet" and not timing_history:can_redo())
assert(triplet.pitch_length==3 and triplet.time_events[32]=="R")
assert(triplet.pitch_events[32].note==straight.pitch_events[32].note and
  triplet.pitch_events[32].accent and triplet.pitch_events[32].slide)
local reset=seq.new_pattern()
assert(timing_history:record(reset,"repeat",0))
assert(timing_history:undo().timing_mode=="triplet")
assert(timing_history:redo().timing_mode=="straight")
timed.timing_mode=nil
assert(not seq.validate(timed))
timed.timing_mode="other"
assert(not seq.validate(timed))
print("ACID editor, paging, octave, preview and diagnostic checks passed")
