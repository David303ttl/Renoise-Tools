dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local planner=require("model.output_planner")
local capabilities=require("renoise.target_capabilities")
local pattrns=require("writers.pattrns_writer")
assert(pattrns.expected_volumes==planner.expected_volumes)
local capacities={max_lines=512,max_note_columns=12,max_effect_columns=8,
  play_pattern=1,key_tracking_none=1}
local sample={sample=true,plugin=false,midi=false,alias=false}
local plugin={sample=false,plugin=true,midi=false,alias=false}
local function run(source,policy,profile,pb,limits,options)
  return planner.plan(source,policy or "play_once",pb or 0,limits or capacities,
    profile,options or {pitch_bend_delivery=true})
end
local function source()
  local pattern=seq.new_pattern(4)
  pattern.pitch_length=2
  pattern.pitch_events[1]=seq.new_pitch(0,0,false,false)
  pattern.pitch_events[2]=seq.new_pitch(7,0,true,false)
  pattern.time_events={"N","T","N","R"}
  for i=5,32 do pattern.time_events[i]="N" end
  return pattern
end
_G.renoise=setmetatable({},{__index=function() error("planner accessed host") end,
  __newindex=function() error("planner mutated host") end})
for _,mode in ipairs({"straight","triplet"}) do
  for _,policy in ipairs({"repeat","play_once"}) do
    local pattern=source()
    pattern.timing_mode=mode
    local output=assert(run(pattern,policy,{}))
    assert(output.layout.lpb==(mode=="straight" and 16 or 12))
    assert(output.layout.number_of_lines==(policy=="repeat" and 33 or 16))
    assert(output.expected.properties.playback_mode==1 and output.expected.properties.key_tracking==1)
    local lines=output.expected.lines
    assert(#lines==512 and #lines[1].note_columns==12 and #lines[1].effect_columns==8)
    assert(lines[1].note_columns[1].note_value==36 and lines[1].note_columns[1].volume_value==89)
    assert(lines[5].note_columns[1].is_empty)
    assert(lines[9].note_columns[1].note_value==43 and lines[9].note_columns[1].volume_value==255)
    assert(lines[7].note_columns[1].note_value==120 and lines[13].note_columns[1].note_value==120)
    assert(lines[512].note_columns[12].is_empty and lines[512].effect_columns[8].is_empty)
    for _,line in ipairs(lines) do
      for _,cell in ipairs(line.note_columns) do
        for _,field in ipairs({"note_value","instrument_value","volume_value","panning_value",
            "delay_value","effect_number_value","effect_amount_value"}) do
          assert(type(cell[field])=="number",field)
        end
        assert(type(cell.is_empty)=="boolean")
      end
      for _,cell in ipairs(line.effect_columns) do
        assert(type(cell.number_value)=="number" and type(cell.amount_value)=="number")
      end
    end
    assert(output.required_visibility.visible_note_columns==1 and
      output.required_visibility.visible_effect_columns==0 and output.required_visibility.volume_column_visible)
    pattern.pitch_events[1].accent=true
    assert(not output.source.pitch_events[1].accent)
    lines[512].note_columns[12].note_value=1
    assert(lines[511].note_columns[12].note_value==121 and output.expected.empty_note.note_value==121)
  end
end
local connected=seq.new_pattern(2)
connected.pitch_length=2
connected.pitch_events[1]=seq.new_pitch(0,0,false,true)
connected.pitch_events[2]=seq.new_pitch(7,0,false,false)
local sampled=assert(run(connected,"play_once",sample))
assert(sampled.expected.lines[5].note_columns[1].effect_number_value==16)
assert(sampled.required_visibility.sample_effects_column_visible)
assert(sampled.expected.lines[7].note_columns[1].note_value==120)
local wide=assert(seq.copy_source(connected))
wide.pitch_events[1]=seq.new_pitch(0,-1,false,true)
wide.pitch_events[2]=seq.new_pitch(12,1,false,false)
local instant=assert(run(wide,"play_once",sample))
assert(instant.expected.lines[5].note_columns[1].effect_amount_value==255)
assert(instant.expected.lines[7].note_columns[1].note_value==120)
assert(table.concat(instant.approximations," "):find("instant transitions",1,true))
local overlap=assert(run(connected,"play_once",plugin))
assert(overlap.native_notes and overlap.required_visibility.visible_note_columns==2)
assert(overlap.expected.lines[5].note_columns[1].note_value==120)
assert(overlap.expected.lines[5].note_columns[1].delay_value==1)
assert(overlap.expected.lines[5].note_columns[2].note_value==43)
local bent=assert(run(connected,"play_once",plugin,12))
assert(bent.expected.lines[1].note_columns[3].panning_value==5633)
assert(bent.expected.lines[1].effect_columns[1].number_value==1024)
assert(bent.required_visibility.visible_note_columns==3 and bent.required_visibility.visible_effect_columns==1)
assert(bent.required_visibility.instrument_column_visible and bent.required_visibility.panning_column_visible)
assert(bent.expected.lines[1].note_columns[1].delay_value==1)
local disabled=assert(run(connected,"play_once",plugin,12,nil,{pitch_bend_delivery=false}))
assert(disabled.native_notes and not disabled.native_notes.midi_commands)
assert(table.concat(disabled.approximations," "):find("unavailable",1,true))
local _,unknown=run(connected,"play_once",{})
assert(unknown:find("unknown",1,true))
local _,malformed_error=run(connected,"play_once",{read_error=setmetatable({},
  {__tostring=function() error("profile formatting has side effects") end})})
assert(malformed_error=="receiver capability is unknown")
assert(run(source(),"play_once",{read_error="unavailable"}))
assert(run(connected,"play_once",{plugin=true}))
assert(not run(connected,"play_once",false))
assert(not run(connected,"play_once",setmetatable({},{__index=function()error("receiver read failed")end})))
assert(not run(connected,"play_once",plugin,12,nil,{}))
assert(not planner.plan(source(),"play_once",0,nil,{}))
local limits={max_lines=512,max_note_columns=1,max_effect_columns=0,play_pattern=1,key_tracking_none=1}
assert(not run(connected,"play_once",plugin,12,limits))
limits.max_lines=4
assert(not run(source(),"repeat",{},0,limits))
for text,value in pairs({["00"]=0,["0G"]=16,["40"]=1024,["7F"]=1807,["0M"]=22,["ZT"]=8989,["M1"]=5633}) do
  assert(planner.command_value(text)==value,text)
end
assert(not planner.command_value("??"))
local unknown_profile=assert(capabilities.inspect({}))
assert(unknown_profile.kind=="unknown" and unknown_profile.sample==nil and unknown_profile.plugin==nil)
assert(run(source(),"play_once",unknown_profile))
assert(not run(connected,"play_once",unknown_profile))
print("ACID pure output planning and complete expected cells passed")
