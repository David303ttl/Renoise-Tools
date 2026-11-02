dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local compiler=require("model.cycle_interpreter")
local planner=require("model.output_planner")
local editor=require("model.editor_state")
local source=seq.new_pattern(6)
for i,note in ipairs({30,35,37,42,59,60}) do
  local key,octave
  if note==60 then key,octave=12,1
  elseif note<36 then key,octave=note-24,-1
  elseif note>48 then key,octave=note-48,1
  else key,octave=note-36,0 end
  source.pitch_events[i]=seq.new_pitch(key,octave,i%2==0,i%3==0)
end
for i=1,6 do source.time_events[i]="N" end
local valid=assert(seq.validate(source))
assert(valid and #source.scale_mask==12 and source.scale_mask_enabled==false)
local source_field_count=0
for _ in pairs(source)do source_field_count=source_field_count+1 end
assert(source_field_count==7,"canonical source must have exactly seven top-level fields")
local resolved=assert(seq.resolve_pitches(source))
for i=1,6 do assert(resolved[i].note==source.pitch_events[i].note) end
local mask=assert(seq.copy_source(source))
for i=1,12 do mask.scale_mask[i]=i==1 end
mask.scale_mask_enabled=true
local masked=assert(seq.resolve_pitches(mask))
local expected={24,36,36,36,60,60}
for i=1,6 do
  assert(masked[i].note==expected[i])
  assert(masked[i].note==36+masked[i].key+12*masked[i].octave)
end
for allowed_class=1,12 do
  local class_mask=assert(seq.copy_source(source))
  for i=1,12 do class_mask.scale_mask[i]=i==allowed_class end
  class_mask.scale_mask_enabled=true
  local class_result=assert(seq.resolve_pitches(class_mask))
  for i=1,32 do assert(class_result[i].note%12+1==allowed_class or class_result[i].note==60 and allowed_class==1) end
end
assert(source.pitch_events[1].note==30 and source.scale_mask_enabled==false)
for _,malformed in ipairs({"missing enabled","missing bits","sparse","extra","nonboolean","enabled empty"}) do
  local candidate=assert(seq.copy_source(source))
  if malformed=="missing enabled" then candidate.scale_mask_enabled=nil
  elseif malformed=="missing bits" then candidate.scale_mask=nil
  elseif malformed=="sparse" then candidate.scale_mask[12]=nil
  elseif malformed=="extra" then candidate.scale_mask[13]=true
  elseif malformed=="nonboolean" then candidate.scale_mask[1]=0
  else candidate.scale_mask_enabled=true;for i=1,12 do candidate.scale_mask[i]=false end end
  assert(not seq.validate(candidate),malformed)
end
local endpoint=assert(seq.copy_source(source))
endpoint.pitch_events[1]=seq.new_pitch(12,1,false,false)
assert(seq.validate(endpoint))
local too_high=assert(seq.copy_source(endpoint));too_high.pitch_events[1].note=61
assert(not seq.validate(too_high))

local prepared=assert(seq.prepare_resolution(mask))
local captured=assert(seq.detach_prepared(prepared,mask))
assert(seq.validate_prepared(captured,mask))
prepared.resolved_records[1].note=36
assert(not seq.validate_prepared(prepared,mask),
  "mutation of the factory-issued bundle must not mutate its private provenance snapshot")
prepared=assert(seq.prepare_resolution(mask))
local forged={source=seq.copy_source(mask),resolved_records=masked,provenance={}}
assert(not seq.validate_prepared(forged,mask))
local changed=assert(seq.copy_source(mask));changed.scale_mask[2]=true
assert(not seq.validate_prepared(captured,changed))
local tampered=assert(seq.detach_prepared(prepared,mask));tampered.resolved_records[1].note=36
assert(not seq.validate_prepared(tampered,mask))
local malformed=assert(seq.detach_prepared(prepared,mask));malformed.resolved_records.extra=true
local malformed_ok=pcall(seq.validate_prepared,malformed,mask)
assert(malformed_ok and not seq.validate_prepared(malformed,mask),
  "malformed record keys must be rejected without throwing")

local events=assert(compiler.compile_cycles(mask,1,nil,captured))[1].steps
assert(events[1].note==24 and events[1].key==0 and events[1].octave==-1)
assert(events[2].note==36 and events[2].accent==true and events[2].slide==false)
local held_source=assert(seq.copy_source(mask))
held_source.length=3
held_source.pitch_length=1
held_source.time_events[1],held_source.time_events[2],held_source.time_events[3]="N","T","R"
local held_bundle=assert(seq.prepare_resolution(held_source))
local held_plan=assert(compiler.compile_cycle(held_source,nil,held_bundle))
assert(held_plan.note_count==1 and held_plan.steps[2].kind=="tie" and
  held_plan.steps[2].note==held_bundle.resolved_records[1].note and
  held_plan.steps[3].kind=="rest" and held_plan.steps[3].released_note==held_plan.steps[2].note)
local projection=editor.project(mask,captured)
assert(not projection.error and projection.mapping[1].note==events[1].note)
local plan=assert(planner.plan_output(mask,"play_once",1024,captured))
assert(plan.steps[1].note==events[1].note)
local control=require("model.control_signals")
local repeat_source=assert(seq.copy_source(mask))
repeat_source.length=2
repeat_source.pitch_length=1
repeat_source.time_events[1],repeat_source.time_events[2]="N","T"
local repeat_bundle=assert(seq.prepare_resolution(repeat_source))
local original_resolver=seq.resolve_pitches
seq.resolve_pitches=function() error("nested consumer re-resolved prepared pitches") end
local shared_projection=editor.project(mask,captured)
assert(not shared_projection.error and shared_projection.mapping[1].note==captured.resolved_records[1].note)
local shared_once=assert(planner.plan_output(mask,"play_once",1024,captured))
assert(shared_once.steps[1].note==captured.resolved_records[1].note)
local semantic=assert(compiler.compile_cycle(repeat_source,nil,repeat_bundle))
local timeline=assert(control.compile(repeat_source,{output_policy="repeat",plan=semantic,
  successor=assert(compiler.compile_cycle(repeat_source,{cycle=2,next_pitch=2,
    voice=semantic.steps[2].voice,hold_intent=semantic.steps[2].hold_intent},repeat_bundle)),
  prepared=repeat_bundle}))
assert(timeline.successor.steps[1].note==repeat_bundle.resolved_records[1].note)
local fallback=assert(control.compile(repeat_source,{output_policy="repeat",prepared=repeat_bundle}))
assert(fallback.successor.steps[1].note==repeat_bundle.resolved_records[1].note)
local repeat_output=assert(planner.plan_output(repeat_source,"repeat",1024,repeat_bundle))
assert(repeat_output.steps[1].note==repeat_bundle.resolved_records[1].note)
local capacities={max_lines=1024,max_note_columns=1,max_effect_columns=0,
  play_pattern=1,key_tracking_none=1}
local capability={sample=true,plugin=false,midi=false,alias=false}
local materialized=assert(planner.plan_for_materialization(repeat_source,"play_once",0,
  capacities,capability,{pitch_bend_delivery=false},repeat_bundle))
assert(materialized.source.scale_mask_enabled and materialized.expected.lines[1].note_columns[1].note_value==
  repeat_bundle.resolved_records[1].note)
seq.resolve_pitches=original_resolver
local resolution_count=0
seq.resolve_pitches=function(value)
  resolution_count=resolution_count+1
  return original_resolver(value)
end
for _,policy in ipairs({"play_once","repeat"}) do
  resolution_count=0
  local direct=assert(control.compile(repeat_source,{output_policy=policy}))
  assert(resolution_count==1,"direct gate compilation must resolve its source exactly once")
  assert(direct.semantic.steps[1].note==repeat_bundle.resolved_records[1].note)
  assert(direct.successor.steps[1].note==repeat_bundle.resolved_records[1].note)
  resolution_count=0
  local supplied=assert(control.compile(repeat_source,{output_policy=policy,
    plan=direct.semantic,successor=direct.successor}))
  assert(resolution_count==1,"supplied gate plan verification must share one resolution")
  assert(supplied.successor.steps[1].note==repeat_bundle.resolved_records[1].note)
end
seq.resolve_pitches=original_resolver
local changed_bundle=assert(seq.detach_prepared(prepared,mask))
changed_bundle.source.scale_mask_enabled=false
assert(not compiler.compile_cycle(mask,nil,changed_bundle))
local history=editor.new_history(mask,"play_once",0,"Untitled",false)
local label_state={pattern=mask,output_policy="play_once",pb_range=0,label="Example",label_custom=true}
assert(editor.classify_difference(history.states[1],label_state)=="label_only")
assert(history:record(mask,"play_once",0,"Example",true))
local history_position,history_revision=history.position,history.revision
local proposal=assert(history:propose("undo"))
assert(history.position==history_position and history.revision==history_revision)
assert(proposal.state.label=="Untitled" and not proposal.state.label_custom)
assert(history:commit(proposal) and history.position==1)
assert(history:record(mask,"play_once",0,"Example",true))
local stale=assert(history:propose("undo"))
assert(history:record(mask,"play_once",0,"Renamed",true))
assert(not history:commit(stale),"stale metadata cursor proposal must reject")
print("ACID scale mask resolution and prepared-plan checks passed")
