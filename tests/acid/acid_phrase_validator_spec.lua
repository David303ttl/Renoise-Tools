dofile('tests/bootstrap.lua')('acid')
local verifier = require("writers.phrase_validator")
local compiler = require("model.cycle_interpreter")
local seq=require("model.sequencer")
local pitch=dofile("tests/acid/pitch_fixture.lua")
local output_planner=require("model.output_planner")
local signals=require("model.control_signals")
local fixture=seq.new_pattern(8)
fixture.pitch_length=4
fixture.pitch_events[1]=pitch(36);fixture.pitch_events[2]=pitch(39,true,false)
fixture.pitch_events[3]=pitch(43);fixture.pitch_events[4]=pitch(41)
for i,command in ipairs({"N","T","N","R","N","N","T","R"}) do fixture.time_events[i]=command end
local plan = assert(compiler.compile_cycle(fixture))
local cells={}
local extra_cells={}
for i=1,257 do cells[i]={note_value=121};extra_cells[i]={note_value=121,effect_number_value=0,effect_amount_value=0} end
for line,note in pairs({[1]=36,[9]=39,[13]=120,[17]=43,[21]=41,[29]=120}) do
  cells[line].note_value=note
end
local phrase={number_of_lines=32,visible_note_columns=2,visible_effect_columns=0,
  lpb=16,shuffle=0,looping=false,loop_start=1,loop_end=32}
function phrase:line(i) return {note_columns={cells[i],extra_cells[i]}} end
local result,err=verifier.verify(phrase,plan,4)
assert(result,err)
assert(result.notes==4 and result.offs==2 and result.lines==32)
local layout={looping=false,loop_start=1,loop_end=32,number_of_lines=32,
  length=8,physical_steps=8,cycle_count=1,sentinel_lines=0,
  lines_per_step=4,half_step_lines=2,lpb=16}
local articulation={effects={[9]=2},release_lines={[7]=true,[19]=true}}
cells[7].note_value=120
cells[19].note_value=120
cells[9].effect_number_string="0G"
cells[9].effect_number_value=1
cells[9].effect_amount_value=2
assert(verifier.verify(phrase,plan,4,layout,articulation))
cells[9].effect_amount_value=3
assert(not verifier.verify(phrase,plan,4,layout,articulation))
cells[9].effect_amount_value=2
cells[3].effect_number_value=4
assert(not verifier.verify(phrase,plan,4,layout,articulation))
cells[3].effect_number_value=0
phrase.loop_end=31
assert(not verifier.verify(phrase,plan,4,layout,articulation))
phrase.loop_end=32
cells[19].note_value=121
assert(not verifier.verify(phrase,plan,4,layout,articulation))
cells[19].note_value=120
cells[9].effect_number_string=nil
cells[9].effect_number_value=0
cells[9].effect_amount_value=0
local repeat_source=seq.new_pattern(32)
repeat_source.pitch_length=32
for step=1,32 do
  repeat_source.time_events[step]="N"
  repeat_source.pitch_events[step]=pitch(36)
end
local repeat_plan,repeat_layout=assert(output_planner.plan_output(repeat_source,"repeat",512))
local repeat_timeline=assert(signals.compile(repeat_source,{plan=repeat_plan,
  successor=repeat_plan.loop.steady,output_policy="repeat"}))
local repeat_releases=assert(signals.release_lines(repeat_timeline,4))
phrase.number_of_lines=257
phrase.looping=true
phrase.loop_start=129
phrase.loop_end=257
phrase.lpb=16
for step,event in ipairs(repeat_plan.steps) do
  cells[(step-1)*4+1].note_value=event.note
end
local repeat_release_map={}
for _,line in ipairs(repeat_releases) do
  cells[line].note_value=120
  repeat_release_map[line]=true
end
local repeat_articulation={release_lines=repeat_release_map}
assert(repeat_layout.number_of_lines==257 and repeat_layout.loop_start==129
  and repeat_layout.loop_end==257 and repeat_layout.sentinel_lines==1)
assert(verifier.verify(phrase,repeat_plan,4,repeat_layout,repeat_articulation))
cells[257].note_value=36
assert(not verifier.verify(phrase,repeat_plan,4,repeat_layout,repeat_articulation))
cells[257].note_value=121
phrase.loop_end=256
assert(not verifier.verify(phrase,repeat_plan,4,repeat_layout,repeat_articulation))
phrase.loop_end=257
cells[5].note_value=121
assert(not verifier.verify(phrase,repeat_plan,4,repeat_layout,repeat_articulation))
cells[5].note_value=36
phrase.number_of_lines=32
phrase.looping=false
phrase.loop_start=1
phrase.loop_end=32
for line=1,32 do cells[line]={note_value=121} end
for step,event in ipairs(plan.steps) do
  local line=(step-1)*4+1
  if event.kind=="note" then cells[line].note_value=event.note
  elseif event.kind=="rest" and event.releases then cells[line].note_value=120 end
end
cells[2].note_value=40
assert(not verifier.verify(phrase,plan,4,layout))
cells[2].note_value=121
-- Native commands hidden in auxiliary fields must not bypass validation.
for _,field in ipairs({"delay_value","instrument_value","panning_value","volume_value"}) do
  cells[2][field]=field=="volume_value" and 0xC0 or 1
  assert(not verifier.verify(phrase,plan,4,layout),field.." was accepted")
  cells[2][field]=nil
end
cells[1].volume_value=0xC0
assert(not verifier.verify(phrase,plan,4,layout),"volume cut command was accepted on a note")
cells[1].volume_value=89
-- A plain native volume is valid; acoustic quantization is verified separately.
phrase.number_of_lines=32
phrase.looping=false
phrase.loop_start=1
phrase.loop_end=32
assert(verifier.verify(phrase,plan,4,layout))
for _,lpb in ipairs({16,12}) do
  local timing_layout={looping=false,loop_start=1,loop_end=32,number_of_lines=32,
    length=8,physical_steps=8,cycle_count=1,sentinel_lines=0,
    lines_per_step=4,half_step_lines=2,lpb=lpb}
  phrase.lpb=lpb
  phrase.shuffle=0
  assert(verifier.verify(phrase,plan,4,timing_layout))
  phrase.lpb=lpb==16 and 12 or 16
  assert(not verifier.verify(phrase,plan,4,timing_layout),"wrong phrase LPB accepted")
  phrase.lpb=lpb
  phrase.shuffle=0.1
  assert(not verifier.verify(phrase,plan,4,timing_layout),"nonzero phrase shuffle accepted")
end
phrase.shuffle=0
assert(verifier.verify(phrase,plan,4,nil,{volumes={[1]={[1]=89,[2]=255}}}))
assert(not verifier.verify(phrase,plan,4,nil,{volumes={[1]={[1]=90,[2]=255}}}),
  "a changed validated native volume was accepted")
local volumes=assert(require("model.output_planner").expected_volumes(plan,4,32,2))
for line=1,32 do cells[line].volume_value=volumes[line][1] end
assert(cells[1].volume_value==89 and cells[9].volume_value==255)
assert(cells[3].volume_value==255 and cells[7].volume_value==255)
assert(verifier.verify(phrase,plan,4,nil,{volumes=volumes}))
for _,line in ipairs({1,9,17,21}) do
  local expected=cells[line].volume_value
  for _,wrong in ipairs({0,64,90,127,128,255}) do
    if wrong~=expected then
      cells[line].volume_value=wrong
      assert(not verifier.verify(phrase,plan,4,nil,{volumes=volumes}),
        "incorrect native accent volume accepted")
    end
  end
  cells[line].volume_value=expected
end
extra_cells[1].volume_value=89
assert(not verifier.verify(phrase,plan,4,nil,{volumes=volumes}))
extra_cells[1].volume_value=255
cells[2].volume_value=89
assert(not verifier.verify(phrase,plan,4,nil,{volumes=volumes}))
cells[2].volume_value=255
phrase.number_of_lines=31
assert(not verifier.verify(phrase,plan,4,layout))
print("ACID native phrase content validation passed")
