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
phrase.number_of_lines=15
assert(not verifier.verify(phrase,plan,2))
print("ACID native phrase content validation passed")
