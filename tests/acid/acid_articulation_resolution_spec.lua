dofile("tests/bootstrap.lua")("acid")
local timing=require("model.timing")
local signals=require("model.control_signals")
local gate_writer=require("writers.gate_writer")
local articulation=require("model.articulation")
local legato=require("model.legato")
local seq=require("model.sequencer")
local compiler=require("model.cycle_interpreter")
local pitch=dofile("tests/acid/pitch_fixture.lua")

local function timeline(at,steps,reason)
  return {steps=steps or 2,events={{kind="gate_off",at=at,reason=reason or "tail",step=1}}}
end

for _,mode in ipairs({"straight","triplet"}) do
  for _,policy in ipairs({"repeat","play_once"}) do
    assert(timing.new(mode,4,policy).lines_per_step==4)
  end
end

local releases=assert(signals.release_lines({steps=2,events={
  {kind="gate_off",at=128,reason="tail"},
  {kind="gate_off",at=64,reason="retrigger"},
  {kind="gate_off",at=192,reason="tail"}}},4))
assert(releases[1]==3 and releases[2]==2 and releases[3]==4)
local fractional=timeline(96)
local rejected,why=signals.release_lines(fractional,4)
assert(not rejected and why:find("not representable on a phrase line",1,true))
local half=timeline(128)
rejected,why=signals.release_lines(half,3)
assert(not rejected and why:find("not representable on a phrase line",1,true))
assert(not signals.release_lines(half,0))
assert(not signals.release_lines(half,1.5))

local semantic={steps={{kind="note",step=1},{kind="note",step=2}}}
local mapped=assert(gate_writer.plan(timeline(128),semantic,nil,4))
assert(mapped.release_lines[3])
assert(not gate_writer.plan(timeline(128),semantic,{{line=3,kind="glide"}},4))
local conflict=timeline(256)
local step_notes={steps={{kind="note",step=1},{kind="note",step=2}}}
rejected,why=gate_writer.plan(conflict,step_notes,nil,4)
assert(not rejected and why:find("OFF conflicts",1,true))
rejected,why=gate_writer.plan(timeline(128),semantic,nil)
assert(not rejected and why:find("positive integer lines-per-step",1,true))

local pattern=seq.new_pattern(2)
pattern.pitch_length=2
pattern.pitch_events[1]=pitch(36,false,true)
pattern.pitch_events[2]=pitch(43)
pattern.time_events[1]="N"
pattern.time_events[2]="N"
local articulation_plan=assert(compiler.compile_cycle(pattern))
local cells={}
for i=1,8 do
  cells[i]={note_value=121,effect_number_value=0,effect_amount_value=0}
end
for step,event in ipairs(articulation_plan.steps) do
  if event.kind=="note" then cells[(step-1)*4+1].note_value=event.note end
end
local phrase={}
function phrase:line(i) return {note_columns={cells[i]}} end
local applied=assert(articulation.apply(phrase,articulation_plan,4,0x40,
  {output_policy="play_once"}))
assert(applied.slide_count==1 and cells[5].effect_number_string=="0G")
assert(cells[7].note_value==120)
assert(not articulation.apply(phrase,articulation_plan,1,0x40,
  {output_policy="play_once"}))

local overlap_semantic={steps={
  {kind="note",step=1,source_step=1,note=36},
  {kind="note",step=2,source_step=2,note=40,from_note=36,transition="slide"}}}
local overlap_timeline={steps=2,events={
  {kind="gate_on",at=0,note=36,step=1,source_step=1,accent=false},
  {kind="pitch_target",at=256,note=40,step=2,source_step=2,accent=false},
  {kind="gate_off",at=384,step=2,source_step=2}}}
local overlap_layout={lines_per_step=4,half_step_lines=2}
local overlap=assert(legato.plan(overlap_semantic,overlap_timeline,overlap_layout))
assert(overlap.lines_per_step==4 and overlap.cells[1][1].note_value==36)
assert(overlap.cells[5][2].note_value==40 and overlap.cells[5][2].delay_value==0)
assert(legato.ORDER_DELAY==1 and overlap.cells[5][1].delay_value==legato.ORDER_DELAY)
assert(overlap.cells[7][2].note_value==legato.OFF and overlap.cells[7][2].delay_value==0)
overlap_timeline.events[3].at=400
local quantized=assert(legato.plan(overlap_semantic,overlap_timeline,overlap_layout))
assert(quantized.cells[7][2].delay_value>0)

local boundary_off=assert(legato.plan({steps={{kind="note",step=1}}},{steps=2,events={
  {kind="gate_on",at=0,note=36,step=1,accent=false},
  {kind="gate_off",at=256,step=2}}},{lines_per_step=4,half_step_lines=2}))
assert(boundary_off.cells[5][1].note_value==legato.OFF and
  boundary_off.cells[5][1].delay_value==0)

local bend_semantic={}
local bend_timeline={steps=2,events={
  {kind="gate_on",at=0,note=36,step=1,accent=false},
  {kind="gate_off",at=128,step=1},
  {kind="gate_on",at=256,note=43,step=2,accent=false}}}
local bend_layout={lines_per_step=4,half_step_lines=2}
local bend=assert(legato.plan(bend_semantic,bend_timeline,bend_layout,
  {pb_range=12,instrument_value=3}))
assert(bend.cells[1][1].delay_value==1 and bend.midi_commands[1].value==8192)
assert(bend.cells[3][1].note_value==legato.OFF and bend.midi_commands[3].value==8192)
assert(bend.cells[5][1].note_value==43 and bend.cells[5][1].delay_value==0)
assert(not bend.midi_commands[5])
local glide=assert(legato.plan({}, {steps=2,events={
  {kind="gate_on",at=0,note=36,step=1,accent=false},
  {kind="pitch_target",at=256,note=40,step=2,accent=false}}},
  bend_layout,{pb_range=12,instrument_value=3}))
assert(glide.midi_commands[3] and glide.midi_commands[5])

print("ACID articulation resolution checks passed")
