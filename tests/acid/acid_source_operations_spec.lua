dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local source=seq.new_pattern(7)
source.pitch_length=5
source.timing_mode="triplet"
source.scale_mask_enabled=true
for i=1,12 do source.scale_mask[i]=i==2 end
for i=1,32 do
  source.pitch_events[i]=seq.new_pitch(i%12,0,true,true)
  source.time_events[i]=i==1 and "N" or (i%2==0 and "T" or "R")
end
local original=assert(seq.copy_source(source))
local operations={clear_pitch="pitch",clear_time="time",clear_tie="time",clear_rest="time",
  clear_slide="pitch",clear_accent="pitch",rest_to_note="time",tie_to_rest="time"}
for operation,memory in pairs(operations) do
  for _,scope in ipairs({"active","all"}) do
    local candidate=assert(seq.operation_candidate(source,operation,scope))
    local expected=assert(seq.copy_source(source))
    local bound=scope=="all" and 32 or (memory=="pitch" and 5 or 7)
    for i=1,bound do
      local pitch=expected.pitch_events[i]
      local command=expected.time_events[i]
      if operation=="clear_pitch" then expected.pitch_events[i]=seq.new_pitch(0,0,false,false)
      elseif operation=="clear_slide" then pitch.slide=false
      elseif operation=="clear_accent" then pitch.accent=false
      elseif operation=="clear_time" then expected.time_events[i]="N"
      elseif operation=="clear_tie" and command=="T" then expected.time_events[i]="N"
      elseif (operation=="clear_rest" or operation=="rest_to_note") and command=="R" then expected.time_events[i]="N"
      elseif operation=="tie_to_rest" and command=="T" then expected.time_events[i]="R" end
    end
    assert(seq.same_source(candidate,expected),operation.." "..scope)
    assert(seq.same_source(candidate,assert(seq.operation_candidate(candidate,operation,scope))),"idempotent")
    assert(seq.same_source(source,original),"source unchanged")
    assert(candidate~=source and candidate.pitch_events[32]~=source.pitch_events[32],"detached")
  end
end
local state=1
local states={16807,282475249,1622650073,984943658,1144108930}
for i=1,5 do
  local bucket
  bucket,state=seq.random_choice(state,37)
  assert(state==states[i])
  assert(bucket+24==({24,28,51,40,43})[i])
end
for _,scope in ipairs({"active","all"}) do
  local pitch=assert(seq.operation_candidate(source,"randomize_pitch",scope,{seed=1,min_note=24,max_note=60}))
  local repeat_pitch=assert(seq.operation_candidate(source,"randomize_pitch",scope,{seed=1,min_note=24,max_note=60}))
  assert(seq.same_source(pitch,repeat_pitch))
  local other_pitch=assert(seq.operation_candidate(pitch,"randomize_pitch",scope,
    {seed=29,min_note=24,max_note=60}))
  local restored_pitch=assert(seq.operation_candidate(other_pitch,"randomize_pitch",scope,
    {seed=1,min_note=24,max_note=60}))
  assert(seq.same_source(pitch,restored_pitch),"returning to a PITCH seed restores its notes without Undo")
  for i=1,5 do assert(pitch.pitch_events[i].note==({25,49,37,37,25})[i]) end
  local time=assert(seq.operation_candidate(source,"randomize_time",scope,
    {seed=1,note_weight=2,tie_weight=1,rest_weight=1}))
  local other_time=assert(seq.operation_candidate(time,"randomize_time",scope,
    {seed=29,note_weight=2,tie_weight=1,rest_weight=1}))
  local restored_time=assert(seq.operation_candidate(other_time,"randomize_time",scope,
    {seed=1,note_weight=2,tie_weight=1,rest_weight=1}))
  assert(seq.same_source(time,restored_time),"returning to a TIME seed restores its commands without Undo")
  for i=1,5 do assert(time.time_events[i]==({"N","R","N","T","N"})[i]) end
  local bound=scope=="all" and 32 or 7
  for i=1,32 do
    assert(time.pitch_events[i].note==source.pitch_events[i].note)
    assert(pitch.time_events[i]==source.time_events[i])
    assert(pitch.pitch_events[i].accent and pitch.pitch_events[i].slide)
    if i>bound then assert(time.time_events[i]==source.time_events[i]) end
    if scope=="active" and i>5 then assert(pitch.pitch_events[i].note==source.pitch_events[i].note) end
  end
  assert(time.length==7 and pitch.pitch_length==5 and time.timing_mode=="triplet")
  assert(time.scale_mask_enabled and pitch.scale_mask[2] and not pitch.scale_mask[1])
end
local chromatic=assert(seq.copy_source(source))
chromatic.scale_mask_enabled=false
local first_notes={}
for seed=1,16 do
  local sample=assert(seq.operation_candidate(chromatic,"randomize_pitch","active",
    {seed=seed,min_note=24,max_note=60}))
  first_notes[sample.pitch_events[1].note]=true
end
local distinct=0
for _ in pairs(first_notes) do distinct=distinct+1 end
assert(distinct>=12,"consecutive seeds must diversify the first pitch")
for note=24,60 do
  local candidate=assert(seq.operation_candidate(chromatic,"randomize_pitch","all",
    {seed=2147483646,min_note=note,max_note=note}))
  for i=1,32 do
    local pitch=candidate.pitch_events[i]
    assert(pitch.note==note and pitch.note==36+pitch.key+12*pitch.octave)
    assert(pitch.key==(note==60 and 12 or note%12))
  end
end
local sparse=assert(seq.copy_source(source))
sparse.scale_mask_enabled=true
for i=1,12 do sparse.scale_mask[i]=(i==1 or i==6) end -- C and F
local sparse_result=assert(seq.operation_candidate(sparse,"randomize_pitch","all",
  {seed=17,min_note=36,max_note=48}))
local first_masked={}
for seed=1,16 do
  local sample=assert(seq.operation_candidate(sparse,"randomize_pitch","active",
    {seed=seed,min_note=36,max_note=48}))
  first_masked[sample.pitch_events[1].note]=true
end
assert(first_masked[36] and first_masked[41] and first_masked[48],
  "consecutive seeds must diversify sparse-scale first pitches")
local sparse_replay=assert(seq.operation_candidate(sparse,"randomize_pitch","all",
  {seed=17,min_note=36,max_note=48}))
assert(seq.same_source(sparse_result,sparse_replay),"masked randomization replays from seed")
for i=1,32 do
  local note=sparse_result.pitch_events[i].note
  assert(note>=36 and note<=48 and (note%12==0 or note%12==5),"randomized pitch respects sparse mask")
end
local no_candidates=assert(seq.copy_source(sparse))
for i=1,12 do no_candidates.scale_mask[i]=i==2 end
local absent,absent_error=seq.operation_candidate(no_candidates,"randomize_pitch","active",
  {seed=1,min_note=36,max_note=36})
assert(not absent and absent_error:find("no allowed notes",1,true))
local constrained=assert(seq.constrain_pitch(sparse,seq.new_pitch(0,0,true,true)))
assert(constrained.note==36 and constrained.accent and constrained.slide,"scale snap preserves flags")
local tie_pitch=seq.new_pitch(0,0,false,false)
tie_pitch.note,tie_pitch.key,tie_pitch.octave=38,2,0
local tie_constrained=assert(seq.constrain_pitch(sparse,tie_pitch))
assert(tie_constrained.note==36,"equal-distance scale snap chooses lower note")
local unchanged=assert(seq.constrain_pitch(chromatic,seq.new_pitch(2,0,true,false)))
assert(unchanged.note==38 and unchanged.accent and not unchanged.slide,"disabled scale returns unchanged pitch")
local alternate_c=seq.new_pitch(12,0,true,true)
local copied_c=assert(seq.constrain_pitch(chromatic,alternate_c))
assert(copied_c~=alternate_c and copied_c.note==48 and copied_c.key==12 and copied_c.octave==0 and
  copied_c.accent and copied_c.slide,"disabled scale preserves detached alternate C+ encoding and flags")
local _,singleton_state=seq.random_choice(1,1)
assert(singleton_state==16807)
local normalized=assert(seq.operation_candidate(source,"randomize_time","all",
  {seed=2147483646,note_weight=0,tie_weight=1000,rest_weight=0}))
assert(normalized.time_events[1]=="N")
for i=2,32 do assert(normalized.time_events[i]=="T") end
for _,command in ipairs({"N","R"}) do
  local candidate=assert(seq.operation_candidate(source,"randomize_time","all",
    {seed=1,note_weight=command=="N" and 1000 or 0,tie_weight=0,rest_weight=command=="R" and 1000 or 0}))
  for i=1,32 do assert(candidate.time_events[i]==command) end
end
for _,seed in ipairs({0,2147483647,-1,1.5,math.huge}) do
  assert(not seq.operation_candidate(source,"randomize_pitch","active",{seed=seed,min_note=24,max_note=60}))
end
for _,range in ipairs({{23,60},{24,61},{40,30},{24.5,60}}) do
  assert(not seq.operation_candidate(source,"randomize_pitch","active",{seed=1,min_note=range[1],max_note=range[2]}))
end
for _,weights in ipairs({{0,0,0},{-1,1,1},{1001,1,1},{0,0.5,1}}) do
  assert(not seq.operation_candidate(source,"randomize_time","all",
    {seed=1,note_weight=weights[1],tie_weight=weights[2],rest_weight=weights[3]}))
end
assert(not seq.operation_candidate(source,"unknown","all"))
assert(not seq.operation_candidate(source,"clear_time","unknown"))
assert(not seq.operation_candidate(source,"randomize_pitch","active"))
assert(not seq.set_time(source,17,"R"))
assert(seq.same_source(source,original))

local bits={}
for i=1,12 do bits[i]=false end
local disabled=assert(seq.mask_candidate(source,false,bits))
assert(not disabled.scale_mask_enabled and not disabled.scale_mask[2])
bits[2]=true
assert(not disabled.scale_mask[2],"mask detached")
assert(not seq.mask_candidate(source,true,disabled.scale_mask),"empty enabled mask")
assert(not seq.mask_candidate(source,"true",bits))
assert(seq.same_source(source,original))
local tie_first=assert(seq.operation_candidate(source,"randomize_time","active",
  {seed=1,note_weight=0,tie_weight=1,rest_weight=1}))
local _,rng_state=seq.random_choice(1,1)
for i=1,7 do
  local bucket
  bucket,rng_state=seq.random_choice(rng_state,2)
  assert(tie_first.time_events[i]==(i==1 and (bucket==0 and "N" or "R") or (bucket==0 and "T" or "R")))
end
local maximal=assert(seq.operation_candidate(source,"randomize_time","active",
  {seed=2147483646,note_weight=1000,tie_weight=1000,rest_weight=1000}))
assert(seq.validate(maximal))
local editor=require("model.editor_state")
local store=require("renoise.pattern_store")
local instrument={name="Operations",phrases={}}
local song={tool_data="",instruments={instrument}}
local random_parameters={
  randomize_pitch={seed=1,min_note=24,max_note=60},
  randomize_time={seed=1,note_weight=2,tie_weight=1,rest_weight=1}}
operations.randomize_pitch="pitch"
operations.randomize_time="time"
local planner=require("model.output_planner")
for operation in pairs(operations) do
  for _,scope in ipairs({"active","all"}) do
    local candidate=assert(seq.operation_candidate(source,operation,scope,random_parameters[operation]))
    for _,output_policy in ipairs({"play_once","repeat"}) do
      local history=editor.new_history(source,output_policy,24,"Scoped source",true)
      assert(history:record(candidate,output_policy,24,"Scoped source",true))
      assert(#history.states==2 and history.position==2)
      assert(not history:record(candidate,output_policy,24,"Scoped source",true))
      local before,policy,pb,label,custom=history:undo()
      assert(seq.same_source(before,source) and policy==output_policy and pb==24)
      assert(label=="Scoped source" and custom)
      local after=history:redo()
      assert(seq.same_source(after,candidate))
      assert(store.write_draft_metadata(song,instrument,nil,after,policy,pb,label,custom))
      local restored,restored_policy,restored_pb,restored_label,restored_custom=
        store.read_draft(song,instrument,nil)
      assert(seq.same_source(restored,candidate),operation.." "..scope.." roundtrip")
      assert(restored_policy==policy and restored_pb==pb and restored_label==label and restored_custom)
      if random_parameters[operation] then
        assert(planner.plan_output(restored,output_policy,512))
        assert(seq.same_source(restored,candidate),"output planning changed randomized raw source")
        assert(seq.same_source(candidate,assert(seq.operation_candidate(source,operation,scope,
          random_parameters[operation]))),"output policy changed RNG vector")
      end
    end
  end
end
print("acid_source_operations_spec: ok")
