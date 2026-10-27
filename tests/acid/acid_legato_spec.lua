dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local cycles=require("model.cycle_interpreter")
local gates=require("model.control_signals")
local legato=require("model.legato")
local phrase_writer=require("writers.phrase_writer")

local function pattern(notes,slides,accents,commands)
  local p=seq.new_pattern(#commands)
  p.pitch_length=#notes
  for i,note in ipairs(notes) do
    local pitch=seq.new_pitch(note-36,0,accents[i] or false,slides[i] or false)
    p.pitch_events[i]=pitch
  end
  for i,command in ipairs(commands) do p.time_events[i]=command end
  return p
end

local function plan(p)
  local semantic=assert(cycles.plan_loop(p))
  local timeline=assert(gates.compile(p,{plan=semantic.steady,
    successor=semantic.verification,output_policy="repeat"}))
  local physical={steps=semantic.steady.steps,loop=semantic}
  return assert(legato.plan(physical,timeline,{lines_per_step=2,max_columns=3}))
end

local function cell(result,line,column)
  return result.cells[line] and result.cells[line][column]
end

local function count_table_keys(values)
  local count=0
  for _ in pairs(values) do count=count+1 end
  return count
end

local function simulate_repeat(p)
  local physical,layout=assert(phrase_writer.plan_output(p,"repeat"))
  local timeline=assert(gates.compile(p,{plan=physical,
    successor=physical.loop.steady,output_policy="repeat"}))
  local native=assert(legato.plan(physical,timeline,{lines_per_step=2,max_columns=3}))
  local active,active_count={},0
  local max_active=0
  local fresh_lines,rest_lines={},{}
  for _,event in ipairs(timeline.events) do
    local line=math.floor(event.at/128)+1
    if event.kind=="gate_on" then fresh_lines[line]=true end
    if event.kind=="rest" then rest_lines[line]=true end
  end

  local function render_line(phrase_line,absolute_line)
    local events={}
    for column=1,native.columns do
      local item=cell(native,phrase_line,column)
      if item and item.note_value~=legato.EMPTY then
        events[#events+1]={column=column,note=item.note_value,
          at=item.delay_value or 0}
      end
    end
    table.sort(events,function(a,b)
      if a.at~=b.at then return a.at<b.at end
      return a.note~=legato.OFF and b.note==legato.OFF
    end)
    for _,event in ipairs(events) do
      if event.note==legato.OFF then
        local old=active[event.column]
        assert(old~=nil,string.format("unpaired OFF at rendered line %d column %d",absolute_line,event.column))
        active[event.column]=nil
        active_count=active_count-1
      else
        assert(active[event.column]==nil,
          string.format("NOTE replaced a held column at rendered line %d column %d",absolute_line,event.column))
        if fresh_lines[phrase_line] then
          assert(active_count==0,"unconnected NOTE began while a prior voice was still active")
        end
        for _,pitch in pairs(active) do
          assert(pitch~=event.note,"overlapping duplicate MIDI pitch creates ambiguous MIDI 1.0 NOTE OFF")
        end
        active[event.column]=event.note
        active_count=active_count+1
      end
      assert(active_count>=0 and active_count<=2,
        string.format("invalid active voice count %d at rendered line %d",active_count,absolute_line))
      if active_count>max_active then max_active=active_count end
    end
    if rest_lines[phrase_line] then
      assert(active_count==0,"REST left a voice active")
    end
  end

  local intro_end=layout.loop_start-1
  for line=1,intro_end do render_line(line,line) end
  local loop_start,loop_end=layout.loop_start,layout.loop_end-1
  local first_snapshot
  local expected_exit=physical.loop.steady.steps[#physical.loop.steady.steps]
  local expected_open=expected_exit.hold_intent and 1 or 0
  for pass=1,2 do
    for line=loop_start,loop_end do
      render_line(line,intro_end+(pass-1)*(loop_end-loop_start+1)+line-loop_start+1)
    end
    local snapshot={}
    for column,pitch in pairs(active) do snapshot[column]=pitch end
    assert(count_table_keys(snapshot)==expected_open,
      "Repeat body exit did not match its semantic gate state")
    if expected_open==1 then
      local expected_voice=expected_exit.voice
      assert(expected_voice~=nil,"held Repeat exit has no semantic voice")
      local found=false
      for _,pitch in pairs(snapshot) do if pitch==expected_voice.note then found=true end end
      assert(found,"Repeat body held the wrong pitch at its seam")
    end
    if first_snapshot then
      for column,pitch in pairs(first_snapshot) do
        assert(snapshot[column]==pitch,"Repeat seam changed the held note/column state")
      end
      for column,pitch in pairs(snapshot) do
        assert(first_snapshot[column]==pitch,"Repeat seam left a stale note/column active")
      end
    else
      first_snapshot=snapshot
    end
  end
  return native,layout,max_active,active
end

-- A connected target NOTE starts at delay zero before the previous voice's
-- OFF at delay one on the same phrase line.
local overlap=plan(pattern({36,40},{true,false},{false,false},{"N","N"}))
local target=assert(cell(overlap,3,2))
local outgoing=assert(cell(overlap,3,1))
assert(target.note_value==40 and target.delay_value==0)
assert(target.volume_value==89)
assert(outgoing.note_value==legato.OFF and outgoing.delay_value==1)
assert(overlap.columns==2)

-- An unconnected NOTE follows a complete midpoint gate and starts a fresh voice.
local fresh=plan(pattern({36,39,43},{false,false,false},{false,false,false},{"N","N","N"}))
assert(cell(fresh,2,1).note_value==legato.OFF)
assert(cell(fresh,2,1).delay_value==0)
assert(cell(fresh,3,fresh.source_columns[2]).note_value==39)

-- REST releases at its boundary; TIE holds the existing note through its step.
local rest=plan(pattern({36,40},{false,false},{false,false},{"N","R"}))
assert(cell(rest,3,1).note_value==legato.OFF)
local tied=plan(pattern({36,40},{false,false},{false,false},{"N","T","N"}))
assert(cell(tied,3,1)==nil)
assert(cell(tied,4,1).note_value==legato.OFF)
assert(cell(tied,5,tied.source_columns[3]).note_value==40)

-- Same-pitch connected transitions hold one voice and report lost accent pressure.
local held=plan(pattern({36,36},{true,false},{false,true},{"N","N"}))
assert(not cell(held,3,1) and not cell(held,3,2))
assert(#held.diagnostics==2 and held.diagnostics[2]:find("TIME step 02",1,true))

-- Equal-pitch connected steps share a note column with their held voice, so a
-- later target cannot reuse that still-active column.
local held_chain=plan(pattern({36,40,40,45},{true,true,true,false},
  {false,false,false,false},{"N","N","N","N"}))
assert(held_chain.source_columns[2]==held_chain.source_columns[3])
assert(held_chain.source_columns[2]~=held_chain.source_columns[4])
assert(cell(held_chain,7,held_chain.source_columns[4]).note_value==45)
assert(cell(held_chain,7,held_chain.source_columns[2]).note_value==legato.OFF)

-- Returning to a recently used MIDI pitch is safe after its earlier OFF; the
-- new NOTE overlaps only the currently held, different pitch.
local returning=plan(pattern({36,40,36},{true,true,false},
  {false,false,false},{"N","N","N"}))
assert(cell(returning,5,returning.source_columns[3]).note_value==36)
assert(cell(returning,5,returning.source_columns[2]).note_value==legato.OFF)
assert(returning.source_columns[3]~=returning.source_columns[2])
local accented=plan(pattern({36},{false},{true},{"N"}))
assert(cell(accented,1,1).volume_value==255)

-- A three-node connected cycle uses three isolated columns, including the seam.
local triangle=plan(pattern({36,39,42},{true,true,true},{false,false,false},{"N","N","N"}))
assert(triangle.columns==3)
assert(cell(triangle,1,triangle.source_columns[1]).note_value==36)
assert(cell(triangle,1,triangle.source_columns[1]).volume_value==89)
assert(cell(triangle,1,triangle.source_columns[3]).note_value==legato.OFF)
assert(cell(triangle,1,triangle.source_columns[3]).delay_value==1)
assert(cell(triangle,3,triangle.source_columns[2]).note_value==39)
assert(cell(triangle,5,triangle.source_columns[3]).note_value==42)
assert(triangle.source_columns[3]~=triangle.source_columns[1])

-- Simulate cold intro plus two steady Repeat passes, including an odd-length
-- connected cycle whose first NOTE overlaps the prior cycle's final voice.
local triangle_pattern=pattern({36,39,42},{true,true,true},{false,false,false},{"N","N","N"})
local _,_,triangle_max,triangle_active=simulate_repeat(triangle_pattern)
assert(triangle_max==2 and count_table_keys(triangle_active)==1)

-- A same-pitch connected seam carries one held voice without duplicating that
-- MIDI pitch, while a REST and later fresh NOTE fully clear each prior voice.
local seam_pattern=pattern({36,40,36},{false,true,true},{false,false,false},{"N","N","N"})
local _,_,seam_max,seam_active=simulate_repeat(seam_pattern)
assert(seam_max==2 and count_table_keys(seam_active)==1)
local reset_pattern=pattern({36,40,43},{true,false,false},{false,false,false},{"N","R","N"})
local _,_,reset_max,reset_active=simulate_repeat(reset_pattern)
assert(reset_max<=2 and count_table_keys(reset_active)==0)

-- A one-note loop keeps the same voice across its seam without allocating a
-- redundant target NOTE or OFF.
local one=plan(pattern({36},{true},{false},{"N"}))
assert(one.columns==1)
assert(not cell(one,1,1) or cell(one,1,1).note_value==36)
assert(not cell(one,1,1) or cell(one,1,1).note_value~=legato.OFF)

local long=seq.new_pattern(64)
long.pitch_length=64
for i=1,64 do
  long.time_events[i]="N"
  long.pitch_events[i]=seq.new_pitch(i%12,math.floor((i-1)/12)%3-1,false,i%2==1)
end
local long_result=plan(long)
assert(long_result.columns<=3)
for step=1,64 do
  assert(long_result.source_columns[step]>=1 and long_result.source_columns[step]<=3)
end

assert(not legato.plan({steps={}},{events={},steps=1},{lines_per_step=1}))
print("ACID plugin/MIDI legato planner checks passed")
