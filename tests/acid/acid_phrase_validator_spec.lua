dofile('tests/bootstrap.lua')('acid')
-- Run from repository root: lua tests/acid/acid_phrase_validator_spec.lua
local verifier = require("writers.phrase_validator")
local compiler = require("model.compiler")
local fixture = {
  length=8,
  pitch_events={{note=36},{note=39,accent=true},{note=43},{note=41}},
  time_events={"N","T","N","R","N","N","T","R"}
}
local plan = assert(compiler.compile(fixture))
local cells={}
for i=1,16 do cells[i]={note_value=121} end
for line,note in pairs({[1]=36,[5]=39,[7]=120,[9]=43,[11]=41,[15]=120}) do
  cells[line].note_value=note
end
local phrase={number_of_lines=16,visible_note_columns=1}
function phrase:line(i) return {note_columns={cells[i]}} end
local result,err=verifier.verify(phrase,plan,2)
assert(result,err)
assert(result.notes==4 and result.offs==2 and result.lines==16)
cells[5].note_value=121
assert(not verifier.verify(phrase,plan,2))
cells[5].note_value=39
cells[2].note_value=40
assert(not verifier.verify(phrase,plan,2))
cells[2].note_value=121
phrase.number_of_lines=15
assert(not verifier.verify(phrase,plan,2))
print("ACID native phrase content validation passed")
