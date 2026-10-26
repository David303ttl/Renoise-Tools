dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local editor=require("model.editor_state")
local compiler=require("model.compiler")
local pattrns=require("writers.pattrns_writer")

for _,length in ipairs({1,16,17,32,33,48,49,64}) do
  local p=seq.new_pattern(length)
  assert(p.length==length)
  for i=1,length do p.time_events[i]=i%4==1 and "N" or i%4==2 and "T" or "R" end
  p.pitch_events={seq.new_pitch(0,0,true,true),seq.new_pitch(3,1),
    seq.new_pitch(5,-1)}
  assert(seq.validate(p))
  local projection=editor.project(p)
  assert(not projection.error)
  assert(projection.note_count==math.floor((length+3)/4))
  local plan,err=compiler.compile(p)
  assert(plan,err)
  local src,meta=pattrns.emit(plan)
  assert(src,meta)
  assert(meta.steps==length)
end
assert(not pcall(seq.new_pattern,65))
assert(editor.page_for(1)==1 and editor.page_for(17)==2)
assert(editor.page_for(33)==3 and editor.page_for(64)==4)
assert(editor.index_on_page(4,16)==64)
for _,octave in ipairs({-1,0,1}) do
  for key=0,12 do
    local p=seq.new_pitch(key,octave,true,false)
    local k,o=seq.pitch_controls(p)
    assert(k==key and o==octave)
    assert(p.note==36+key+12*octave)
    assert(seq.validate({length=1,pitch_events={p},time_events={"N"}}))
  end
end
local mismatched=seq.new_pitch(0,0)
mismatched.note=37
local valid,diagnostic=seq.validate({length=1,pitch_events={mismatched},time_events={"N"}})
assert(not valid)
assert(diagnostic=="pitch keyboard/octave does not match MIDI note at pitch entry 1")
local bad=seq.new_pattern(17)
bad.pitch_events={seq.new_pitch(0,0),seq.new_pitch(3,1)}
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
bad.pitch_events={}
preview=editor.project(bad)
assert(preview.error and preview.error.step==16 and preview.error.pitch_index==1)
assert(preview.mapping[16].missing_pitch)
bad.time_events[16]=nil
preview=editor.project(bad)
assert(preview.error and preview.error.step==16)
bad.time_events[16]="Q"
preview=editor.project(bad)
assert(preview.error and preview.error.step==16)
local off=seq.new_pattern(64)
off.pitch_events={seq.new_pitch(0,0),seq.new_pitch(7,0)}
for i=1,64 do off.time_events[i]=(i==1 or i==64) and "N" or "R" end
local plan=assert(compiler.compile(off))
assert(plan.steps[64].pitch_index==2 and plan.note_count==2)
print("ACID M1: 64-step editor, paging, octave, preview and diagnostics passed")
