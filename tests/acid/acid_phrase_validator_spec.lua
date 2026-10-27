dofile('tests/bootstrap.lua')('acid')
local verifier = require("writers.phrase_validator")
local compiler = require("model.cycle_interpreter")
local seq=require("model.sequencer")
local fixture=seq.new_pattern(8,"extended")
fixture.pitch_length=4
fixture.pitch_events[1]={note=36};fixture.pitch_events[2]={note=39,accent=true}
fixture.pitch_events[3]={note=43};fixture.pitch_events[4]={note=41}
fixture.time_events={"N","T","N","R","N","N","T","R"}
local plan = assert(compiler.compile_cycle(fixture))
local cells={}
local extra_cells={}
for i=1,16 do cells[i]={note_value=121};extra_cells[i]={note_value=121,effect_number_value=0,effect_amount_value=0} end
for line,note in pairs({[1]=36,[5]=39,[7]=120,[9]=43,[11]=41,[15]=120}) do
  cells[line].note_value=note
end
local phrase={number_of_lines=16,visible_note_columns=2,visible_effect_columns=0,
  looping=false,loop_start=1,loop_end=16}
cells[17]={note_value=121};extra_cells[17]={note_value=121,effect_number_value=0,effect_amount_value=0}
function phrase:line(i) return {note_columns={cells[i],extra_cells[i]}} end
local result,err=verifier.verify(phrase,plan,2)
assert(result,err)
assert(result.notes==4 and result.offs==2 and result.lines==16)
local layout={looping=false,loop_start=1,loop_end=16}
local articulation={effects={[5]=2},release_lines={[4]=true}}
cells[4].note_value=120
cells[5].effect_number_string="0G"
cells[5].effect_number_value=1
cells[5].effect_amount_value=2
assert(verifier.verify(phrase,plan,2,layout,articulation))
cells[5].effect_amount_value=3
assert(not verifier.verify(phrase,plan,2,layout,articulation))
cells[5].effect_amount_value=2
cells[3].effect_number_value=4
assert(not verifier.verify(phrase,plan,2,layout,articulation))
cells[3].effect_number_value=0
phrase.loop_end=15
assert(not verifier.verify(phrase,plan,2,layout,articulation))
phrase.loop_end=16
cells[4].note_value=121
cells[5].effect_number_string=nil
cells[5].effect_number_value=0
cells[5].effect_amount_value=0
phrase.number_of_lines=17
phrase.looping=true
phrase.loop_start=9
phrase.loop_end=17
assert(verifier.verify(phrase,plan,2,
  {looping=true,loop_start=9,loop_end=17,number_of_lines=17}))
cells[17].note_value=36
assert(not verifier.verify(phrase,plan,2,
  {looping=true,loop_start=9,loop_end=17,number_of_lines=17}))
cells[17].note_value=121
phrase.loop_end=16
assert(not verifier.verify(phrase,plan,2,
  {looping=true,loop_start=9,loop_end=17,number_of_lines=17}))
cells[5].note_value=121
assert(not verifier.verify(phrase,plan,2))
cells[5].note_value=39
cells[2].note_value=40
assert(not verifier.verify(phrase,plan,2))
cells[2].note_value=121
-- Native commands hidden in auxiliary fields must not bypass validation.
for _,field in ipairs({"delay_value","instrument_value","panning_value","volume_value"}) do
  cells[2][field]=field=="volume_value" and 0xC0 or 1
  assert(not verifier.verify(phrase,plan,2),field.." was accepted")
  cells[2][field]=nil
end
cells[1].volume_value=0xC0
assert(not verifier.verify(phrase,plan,2),"volume cut command was accepted on a note")
cells[1].volume_value=89
-- A plain native volume is valid; acoustic quantization is verified separately.
phrase.number_of_lines=16
phrase.looping=false
phrase.loop_start=1
phrase.loop_end=16
assert(verifier.verify(phrase,plan,2))
assert(verifier.verify(phrase,plan,2,nil,{volumes={[1]={[1]=89,[2]=255}}}))
assert(not verifier.verify(phrase,plan,2,nil,{volumes={[1]={[1]=90,[2]=255}}}),
  "a changed validated native volume was accepted")
local volumes=assert(require("writers.pattrns_writer").expected_volumes(plan,2,16,2))
for line=1,16 do cells[line].volume_value=volumes[line][1] end
assert(cells[1].volume_value==89 and cells[5].volume_value==255)
assert(cells[3].volume_value==255 and cells[7].volume_value==255)
assert(verifier.verify(phrase,plan,2,nil,{volumes=volumes}))
for _,line in ipairs({1,5,9,11}) do
  local expected=cells[line].volume_value
  for _,wrong in ipairs({0,64,90,127,128,255}) do
    if wrong~=expected then
      cells[line].volume_value=wrong
      assert(not verifier.verify(phrase,plan,2,nil,{volumes=volumes}),
        "incorrect native accent volume accepted")
    end
  end
  cells[line].volume_value=expected
end
extra_cells[1].volume_value=89
assert(not verifier.verify(phrase,plan,2,nil,{volumes=volumes}))
extra_cells[1].volume_value=255
cells[2].volume_value=89
assert(not verifier.verify(phrase,plan,2,nil,{volumes=volumes}))
cells[2].volume_value=255
phrase.number_of_lines=15
assert(not verifier.verify(phrase,plan,2))
print("ACID native phrase content validation passed")
