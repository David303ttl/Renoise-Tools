dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local gates=require("model.control_signals")
local writer=require("writers.phrase_writer")
local legato=require("model.legato")

local function render(notes,slides,range,policy,commands,mode)
  local p=seq.new_pattern(commands and #commands or #notes)
  p.timing_mode=mode or 'straight'
  p.pitch_length=#notes
  for i,note in ipairs(notes) do
    local octave=math.floor((note-36)/12)
    p.pitch_events[i]=seq.new_pitch((note-36)%12,octave,false,slides[i] or false)
  end
  for i=1,p.length do p.time_events[i]=commands and commands[i] or "N" end
  local plan,layout=assert(writer.plan_output(p,policy or "play_once"))
  local timeline=assert(gates.compile(p,{plan=plan,successor=plan.loop and plan.loop.steady,output_policy=policy or "play_once"}))
  return assert(legato.plan(plan,timeline,layout,{pb_range=range,instrument_value=3})),timeline
end
local function attacks(plan)
  local count=0
  for _,row in pairs(plan.cells) do for _,cell in pairs(row) do
    if cell.note_value<120 then count=count+1 end
  end end
  return count
end

local up=render({36,43},{true,false},12)
assert(attacks(up)==1)
assert(up.midi_commands[1].value==8192 and up.midi_commands[1].number_string=="40")
assert(up.midi_commands[2].value==math.floor(8192+3.5/12*8191+0.5))
assert(up.midi_commands[3].value==math.floor(8192+7/12*8191+0.5))
assert(not table.concat(up.diagnostics," "):find("SLIDE approximated",1,true))
assert(up.midi_commands[4].value==8192)
assert(up.cells[1][1].delay_value==1 and up.cells[4][1].note_value==120)
local default_channel=assert(legato.plan({}, {events={{kind='gate_on',at=0,note=36,step=1,accent=false}},steps=1},
  {lines_per_step=2},{pb_range=12,instrument_value=255}))
assert(default_channel.midi_commands[1].instrument_value==255)
local down=render({43,36},{true,false},12)
assert(down.midi_commands[2].value==math.floor(8192-3.5/12*8192+0.5))
assert(down.midi_commands[3].value==math.floor(8192-7/12*8192+0.5))
local chain=render({36,40,43},{true,true,false},12)
assert(attacks(chain)==1)
assert(chain.midi_commands[2].value==math.floor(8192+2/12*8191+0.5))
assert(chain.midi_commands[3].value==math.floor(8192+4/12*8191+0.5))
assert(chain.midi_commands[4].value==math.floor(8192+5.5/12*8191+0.5))
assert(chain.midi_commands[5].value==math.floor(8192+7/12*8191+0.5))
local same=render({36,36},{true,false},12)
assert(attacks(same)==1 and not same.midi_commands[3])
local exceeded=render({36,43},{true,false},2)
assert(attacks(exceeded)==2)
assert(exceeded.cells[3][1].note_value==120 and exceeded.cells[3][2].note_value==43)
assert(exceeded.cells[3][2].delay_value==1 and exceeded.midi_commands[3].value==8192)
assert(table.concat(exceeded.diagnostics," "):find("TIME step 02: SLIDE approximated: bend range exceeded",1,true))
local accumulated=render({36,43,50},{true,true,false},12)
assert(attacks(accumulated)==2 and accumulated.midi_commands[5].value==8192)
assert(table.concat(accumulated.diagnostics," "):find("TIME step 03: SLIDE approximated: bend range exceeded",1,true))
local positive=render({36,48},{true,false},12)
local negative=render({48,36},{true,false},12)
assert(positive.midi_commands[3].value==16383 and negative.midi_commands[3].value==0)
local fresh=render({36,43,40},{true,false,false},12)
assert(attacks(fresh)==2 and fresh.midi_commands[4].value==8192 and fresh.midi_commands[5].value==8192)
local seam=render({36,40,43},{true,true,true},12,"repeat")
assert(seam.midi_commands and attacks(seam)==1)
assert(seam.midi_commands[6].value~=8192 and seam.midi_commands[7].value==8192)
for _,mode in ipairs({'straight','triplet'}) do
  local ordered=render({36,43},{true,false},2,'play_once',nil,mode)
  assert(ordered.midi_commands[1].value==8192 and ordered.cells[1][1].delay_value==1)
  assert(ordered.midi_commands[3].value==8192 and ordered.cells[3][2].delay_value==1)
  local loop=render({36,40,43},{true,true,true},12,'repeat',nil,mode)
  assert(loop.midi_commands[6].value~=8192 and loop.midi_commands[7].value==8192)
  assert(attacks(loop)==1)
end
local unsafe=render({24,38,52},{true,true,true},12,"repeat")
assert(not unsafe.midi_commands)
assert(table.concat(unsafe.diagnostics," "):find("loop seam",1,true))
local rest=render({36,43},{true,false},12,"play_once",{"N","N","R"})
assert(rest.midi_commands[5].value==8192 and rest.cells[5][1].note_value==120)
for _,range in ipairs({2,12,24,48}) do
  local result=render({36,38},{true,false},range)
  assert(result.midi_commands[3].value<=16383)
end
local accent_plan=assert(legato.plan({}, {events={
  {kind="gate_on",at=0,note=36,step=1,accent=false},
  {kind="pitch_target",at=256,note=40,step=2,accent=true},
  {kind="gate_off",at=384,step=2}},steps=2},{lines_per_step=2},
  {pb_range=12,instrument_value=0}))
assert(table.concat(accent_plan.diagnostics," "):find("TIME step 02: accent change",1,true))
local cramped=assert(legato.plan({}, {events={
  {kind="gate_on",at=0,note=36,step=1,accent=false},
  {kind="pitch_target",at=128,note=40,step=2,accent=false},
  {kind="gate_off",at=256,step=2}},steps=2},{lines_per_step=2},
  {pb_range=12,instrument_value=0}))
assert(cramped.midi_commands[1].value==8192)
assert(cramped.midi_commands[2].value==math.floor(8192+4/12*8191+0.5))
assert(table.concat(cramped.diagnostics," "):find("no free intermediate bend line",1,true))
assert(not legato.plan({}, {events={{kind="gate_on",at=1,note=36}},steps=1}, {},
  {pb_range=12,instrument_value=0}))
print("ACID pitch-bend anchor, endpoints, release and seam checks passed")
