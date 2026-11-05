dofile('tests/bootstrap.lua')('acid')
local validator=require('writers.phrase_validator')
local materializer=require('writers.phrase_materializer')
local ownership=require('renoise.phrase_ownership')
local planner=require('model.output_planner')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local phrase_fixture=dofile('tests/acid/complete_phrase_fixture.lua')
local capacities={max_lines=512,max_note_columns=12,max_effect_columns=8,play_pattern=1,key_tracking_none=1}
local sample={sample=true,plugin=false,midi=false,alias=false}
local options={pitch_bend_delivery=true}
local source=seq.new_pattern(4)
source.pitch_length=2
source.pitch_events[1]=seq.new_pitch(0,0,false,false)
source.pitch_events[2]=seq.new_pitch(7,0,true,false)
source.time_events[2]='T';source.time_events[4]='R'
local function output(pattern,policy,profile,pb)
 return assert(planner.plan(pattern,policy or 'play_once',pb or 0,capacities,profile or sample,options))
end
local function materialization_output(pattern,policy,profile,pb)
 return assert(planner.plan_for_materialization(pattern,policy or 'play_once',pb or 0,
  capacities,profile or sample,options))
end
local function apply(phrase,planned)
 for key,value in pairs(planned.expected.properties)do phrase[key]=value end
 for key,value in pairs(planned.required_visibility)do phrase[key]=value end
 for line_index,line in ipairs(planned.expected.lines)do
  for column,cell in ipairs(line.note_columns)do
   for key,value in pairs(cell)do phrase.lines[line_index].note_columns[column][key]=value end
  end
  for column,cell in ipairs(line.effect_columns)do
   for key,value in pairs(cell)do phrase.lines[line_index].effect_columns[column][key]=value end
  end
 end
 phrase.name=assert(ownership.make_name_from_verified_snapshot(assert(ownership.snapshot(phrase)),1))
end
local planned=output(source)
local materialization_plan=materialization_output(source)
assert(materialization_plan.expected.lines[512].note_columns[12]==
  materialization_plan.expected.lines[512].note_columns[11],
  'private materialization plan does not share its per-plan empty cells')
local second_materialization_plan=materialization_output(source)
assert(materialization_plan.expected.lines[512].note_columns[12]~=
  second_materialization_plan.expected.lines[512].note_columns[12],
  'private empty cells leaked across independently generated plans')
local public_probe=output(source)
assert(public_probe.expected.lines[512].note_columns[12]~=
  public_probe.expected.lines[512].note_columns[11],
  'public planner output aliases independently mutable cells')
public_probe.expected.lines[512].note_columns[12].note_value=1
assert(public_probe.expected.lines[512].note_columns[11].note_value==121,
  'mutating a public expected cell changed its neighbor')
local phrase=phrase_fixture();apply(phrase,planned)
local instrument={name='complete fixture',phrases={phrase}}
local song={instruments={instrument},tool_data=''}
assert(store.save(song,1,source,'play_once',0))
local function classify(profile,opts)
 return validator.classify(song,instrument,phrase,profile or sample,capacities,opts or options)
end
local function classify_phrase(target,committed_source,profile,policy,pb_range)
 local target_instrument={name='compatibility fixture',phrases={target}}
 local target_song={instruments={target_instrument},tool_data=''}
 local id=assert(ownership.id(target))
 assert(store.save(target_song,id,committed_source,policy or 'play_once',pb_range or 0))
 return validator.classify(target_song,target_instrument,target,profile or sample,capacities,options)
end
local candidate=assert(classify())
assert(candidate.kind=='owned' and seq.same_source(candidate.source,source))
assert(ownership.compare(candidate.baseline,assert(ownership.snapshot(phrase))))
local materialized_phrase=phrase_fixture();apply(materialized_phrase,materialization_plan)
local materialized_result=assert(classify_phrase(materialized_phrase,source))
assert(materialized_result.kind=='owned',
 'private materialization plan differs from the compatible public output')
local detached_candidate=assert(ownership.copy_snapshot(candidate.baseline))
local detached_index=assert(ownership.snapshot_index(detached_candidate,capacities))
local untrusted,_,untrusted_kind=validator.classify_against(song,instrument,phrase,sample,
 capacities,options,detached_candidate,detached_index)
assert(not untrusted and untrusted_kind=='unavailable',"detached snapshots cannot authorize fast revalidation")
local sealed_snapshot,sealed_index=validator.retained_baseline(candidate.baseline)
local baseline_identity=validator.retained_baseline_identity(sealed_snapshot)
assert(validator.is_retained_baseline_identity(baseline_identity,sealed_snapshot))
assert(not validator.is_retained_baseline_identity({},sealed_snapshot) and
 not validator.is_retained_baseline_identity(baseline_identity,detached_candidate),
 "baseline identity tokens must match validator-retained snapshots")

local limits={max_lines=capacities.max_lines,max_note_columns=capacities.max_note_columns,
 max_effect_columns=capacities.max_effect_columns}
local function verified_postimage()
 local ok,token=materializer.apply(phrase,planned.expected,planned.required_visibility,nil,limits,
  planned,candidate.planning_inputs)
 assert(ok)
 local name=assert(materializer.name_for_verified_output(token,1))
 phrase.name=name
 return token
end
local postimage=verified_postimage()
local authorized_name=phrase.name
local function classify_postimage(image,name,plan,inputs)
 image=image or verified_postimage()
 return validator.classify_verified_postimage(song,instrument,phrase,sample,capacities,options,
  image,1,name or authorized_name,plan or planned,inputs or candidate.planning_inputs)
end
postimage.modified=true
assert(not validator.classify_verified_postimage(song,instrument,phrase,sample,capacities,options,
 postimage,1,authorized_name,planned,candidate.planning_inputs),
 "adding fields to the opaque token must invalidate its receipt")
postimage.modified=nil
local fast_candidate=assert(validator.classify_verified_postimage(song,instrument,phrase,sample,
 capacities,options,postimage,1,authorized_name,planned,candidate.planning_inputs))
assert(fast_candidate.kind=='owned' and fast_candidate.baseline==postimage and
 seq.same_source(fast_candidate.source,source),
 "verified postimage classification must reuse the supplied image and committed source")
assert(not validator.classify_verified_postimage(song,instrument,phrase,sample,capacities,options,
 postimage,1,authorized_name,planned,candidate.planning_inputs),
 "a consumed materializer receipt must not be reusable")
local retained_postimage=assert(validator.retained_baseline(postimage))
local forged_postimage=assert(ownership.copy_snapshot(retained_postimage))
forged_postimage.properties.lpb=forged_postimage.properties.lpb+1
assert(not validator.classify_verified_postimage(song,instrument,phrase,sample,capacities,options,
 forged_postimage,1,authorized_name,planned,candidate.planning_inputs),
 "forged postimage fields must fail the fresh live match")
local forged_name=assert(ownership.copy_snapshot(postimage))
local seal=assert(authorized_name:match("%[v3:(%x+)%]"))
local replacement=seal:sub(-1)=="0" and "1" or "0"
forged_name.name=authorized_name:sub(1,-2)..replacement.."]"
assert(not validator.classify_verified_postimage(song,instrument,phrase,sample,capacities,options,
 forged_name,1,forged_name.name,planned,candidate.planning_inputs),
 "a different valid-format seal must not be adopted")
local wrong_source=assert(seq.copy_source(source))
wrong_source.pitch_events[1]=seq.new_pitch(2,0,false,false)
local wrong_source_plan={source=wrong_source,settings=planned.settings,expected=planned.expected,
 required_visibility=planned.required_visibility}
assert(not classify_postimage(nil,authorized_name,wrong_source_plan),
 "a plan with a different source must be rejected")
local wrong_settings={output_policy=planned.settings.output_policy,pb_range=planned.settings.pb_range+1}
local wrong_settings_plan={source=planned.source,settings=wrong_settings,expected=planned.expected,
 required_visibility=planned.required_visibility}
assert(not classify_postimage(nil,authorized_name,wrong_settings_plan),
 "a plan with different PB settings must be rejected")
local wrong_expected=assert(ownership.copy_snapshot(planned.expected))
wrong_expected.properties.lpb=wrong_expected.properties.lpb+1
local wrong_expected_plan={source=planned.source,settings=planned.settings,expected=wrong_expected,
 required_visibility=planned.required_visibility}
assert(not classify_postimage(nil,authorized_name,wrong_expected_plan),
 "a plan with forged expected output fields must be rejected")
local wrong_inputs=assert(ownership.copy_snapshot(candidate.planning_inputs))
wrong_inputs.options.pitch_bend_delivery=not wrong_inputs.options.pitch_bend_delivery
assert(not classify_postimage(nil,authorized_name,planned,wrong_inputs),
 "planning input drift must be rejected")
local mutable_source=assert(seq.copy_source(source))
local mutable_plan={source=mutable_source,settings=planned.settings,expected=planned.expected,
 required_visibility=planned.required_visibility}
local receipt_ok,receipt_image=materializer.apply(phrase,planned.expected,planned.required_visibility,nil,
 limits,mutable_plan,candidate.planning_inputs)
assert(receipt_ok)
local mutable_name=assert(materializer.name_for_verified_output(receipt_image,1))
phrase.name=mutable_name
mutable_plan.source.pitch_events[1]=seq.new_pitch(6,0,false,false)
assert(not validator.classify_verified_postimage(song,instrument,phrase,sample,capacities,options,
 receipt_image,1,mutable_name,mutable_plan,candidate.planning_inputs),
 "mutating a planned source after materialization must invalidate its receipt")
local changed_committed=assert(seq.copy_source(source))
changed_committed.pitch_events[1]=seq.new_pitch(3,0,false,false)
assert(store.save(song,1,changed_committed,'play_once',0))
local source_guarded=validator.classify_verified_postimage(song,instrument,phrase,sample,
 capacities,options,verified_postimage(),1,authorized_name,planned,candidate.planning_inputs)
assert(not source_guarded,"postimage classification must reject a source that no longer produces it")
assert(store.save(song,1,source,'play_once',0))

local function retained_proof_lifetime()
 local proof_phrase=phrase_fixture();apply(proof_phrase,planned)
 local proof_instrument={name='retained proof',phrases={proof_phrase}}
 local proof_song={instruments={proof_instrument},tool_data=''}
 assert(store.save(proof_song,1,source,'play_once',0))
 local public_candidate=assert(validator.classify(proof_song,proof_instrument,proof_phrase,
  sample,capacities,options))
 local sealed,index,identity,proof_reference=validator.retained_baseline(public_candidate.baseline)
 assert(proof_reference and type(proof_reference)=='table')
 local weak=setmetatable({public_candidate.baseline,sealed,identity},{__mode='v'})
 return weak,proof_reference,index,proof_song,proof_instrument,proof_phrase
end
local retained_weak,proof_reference,proof_index,proof_song,proof_instrument,proof_phrase=
 retained_proof_lifetime()
for _=1,3 do collectgarbage('collect') end
assert(retained_weak[1]==nil and retained_weak[2]~=nil,
 "inventory proof references must release the duplicate public phrase snapshot")
local proof_result=assert(validator.classify_against(proof_song,proof_instrument,proof_phrase,
 sample,capacities,options,proof_reference,proof_index))
assert(rawequal(proof_result.baseline,retained_weak[2]),
 "opaque proof reference did not retain its sealed phrase baseline")
local reference_result=assert(validator.classify_against_reference(proof_song,proof_instrument,proof_phrase,
 sample,capacities,options,proof_reference))
assert(rawequal(reference_result.baseline,retained_weak[2]),
 "opaque reference classification must reuse the private retained image")
local proof_name=proof_phrase.name
proof_phrase.name=assert(ownership.make_name_from_verified_snapshot(assert(ownership.snapshot(proof_phrase)),2))
assert(not validator.classify_against_reference(proof_song,proof_instrument,proof_phrase,
 sample,capacities,options,proof_reference),"opaque references must reject a changed exact phrase name")
assert(not validator.classify_against(proof_song,proof_instrument,proof_phrase,
 sample,capacities,options,proof_reference,proof_index),"snapshot checks must reject a changed exact phrase name")
proof_phrase.name=proof_name
proof_result=nil
reference_result=nil
proof_reference=nil
proof_index=nil
for _=1,3 do collectgarbage('collect') end
assert(retained_weak[2]==nil and retained_weak[3]==nil,
 "sealed phrase baselines and identities must collect after their proof reference is released")

local original_plan,plan_calls=planner.plan,0
planner.plan=function(...)
 plan_calls=plan_calls+1
 return original_plan(...)
end
assert(validator.classify_against(song,instrument,phrase,sample,capacities,options,
 candidate.baseline,sealed_index))
assert(plan_calls==0,"unchanged committed inputs must reuse the retained compatibility proof")
local plugin_profile={sample=false,plugin=true,midi=false,alias=false,read_error=false}
local receiver_changed=assert(validator.classify_against(song,instrument,phrase,plugin_profile,capacities,options,
 candidate.baseline,sealed_index))
assert(plan_calls==0 and receiver_changed.planning_inputs.capabilities.sample==true,
 "receiver changes must preserve the verified committed receiver association")
local delivery_changed=assert(validator.classify_against(song,instrument,phrase,sample,capacities,
 {pitch_bend_delivery=false},candidate.baseline,sealed_index))
assert(plan_calls==0 and delivery_changed.planning_inputs.options.pitch_bend_delivery==true,
 "current delivery options must not relabel the committed output")
local volume_changed=assert(validator.classify_against(song,instrument,phrase,sample,capacities,
 {pitch_bend_delivery=true,normal_volume=0.5},candidate.baseline,sealed_index))
assert(plan_calls==0 and volume_changed.planning_inputs.options.normal_volume==
 receiver_changed.planning_inputs.options.normal_volume,
 "current renderer options must not relabel the committed output")
local changed_source=assert(seq.copy_source(source))
changed_source.pitch_events[1]=seq.new_pitch(2,0,false,false)
assert(store.save(song,1,changed_source,'play_once',0))
assert(not validator.classify_against(song,instrument,phrase,sample,capacities,options,
 candidate.baseline,sealed_index))
assert(plan_calls==1,"changed committed source must rebuild and reject incompatible output")
assert(store.save(song,1,source,'repeat',0))
local changed_policy=validator.classify_against(song,instrument,phrase,sample,capacities,options,
 candidate.baseline,sealed_index)
assert(not changed_policy,"changed committed settings cannot reuse old compatibility proof")
assert(plan_calls==2,"changed committed settings must rebuild compatibility proof")
assert(store.save(song,1,source,'play_once',0))
planner.plan=original_plan
local retained_lpb=candidate.baseline.properties.lpb
candidate.baseline.properties.lpb=retained_lpb+1
local retained_proof=assert(validator.classify_against(song,instrument,phrase,sample,
 capacities,options,candidate.baseline,sealed_index))
assert(retained_proof.baseline.properties.lpb==retained_lpb,
 "mutating a returned baseline cannot mutate retained verification evidence")
candidate.baseline.properties.lpb=retained_lpb
local before=song.tool_data
local draft=assert(seq.copy_source(source));draft.pitch_events[1]=seq.new_pitch(2,0,false,false)
assert(store.write_draft(song,instrument,phrase,draft,'repeat',12))
local with_draft=song.tool_data
assert(seq.same_source(assert(classify()).source,source))
assert(song.tool_data==with_draft)
local standalone=assert(classify())
source.pitch_events[32].accent=true
assert(not standalone.source.pitch_events[32].accent)
source.pitch_events[32].accent=false
-- Valid independent source and seal do not establish their association.
assert(store.save(song,1,draft,'play_once',0))
assert(ownership.status(phrase)=='owned' and store.load(song,instrument,phrase))
local rejected,reason,kind=classify()
assert(not rejected and reason:find('Committed',1,true) and kind=='unavailable')
package.loaded['writers.phrase_validator']=nil
validator=require('writers.phrase_validator')
assert(not classify())
assert(not validator.classify(song,instrument,phrase,sample,capacities,{draft=source,pitch_bend_delivery=true}))
assert(store.save(song,1,source,'play_once',0))
assert(classify())
local function rejects(object,key,changed)
 local old,name=object[key],phrase.name
 object[key]=changed;phrase.name=assert(ownership.make_name_from_verified_snapshot(assert(ownership.snapshot(phrase)),1))
 local ok,message,status=classify()
 assert(not ok and message and status=='unavailable',key)
 object[key]=old;phrase.name=name
end
for _,key in ipairs({'number_of_lines','lpb','shuffle','loop_start','loop_end','playback_mode','key_tracking'})do
 rejects(phrase,key,phrase[key]+1)
end
rejects(phrase,'looping',not phrase.looping)
for _,key in ipairs({'note_value','instrument_value','volume_value','panning_value','delay_value','effect_number_value','effect_amount_value'})do
 local cell=phrase.lines[1].note_columns[1]
 rejects(cell,key,cell[key]==255 and 254 or cell[key]+1)
end
for _,key in ipairs({'number_value','amount_value'})do rejects(phrase.lines[1].effect_columns[1],key,1)end
rejects(phrase.lines[1].note_columns[1],'is_empty',true)
rejects(phrase.lines[1].effect_columns[1],'is_empty',false)
-- Extra visible empty columns are supported; hidden ancillary data is blocked.
phrase.visible_note_columns=12;phrase.visible_effect_columns=8;phrase.name=assert(ownership.make_name_from_verified_snapshot(assert(ownership.snapshot(phrase)),1))
assert(classify())
apply(phrase,planned)
local note=phrase.lines[1].note_columns[12]
note.delay_value=1;note.is_empty=false
assert(not classify())
note.delay_value=0;note.is_empty=true
local tail=phrase.lines[512].note_columns[1]
tail.instrument_value=1;tail.is_empty=false
assert(not classify())
tail.instrument_value=255;tail.is_empty=true
local effect=phrase.lines[512].effect_columns[8]
effect.amount_value=1;effect.is_empty=false
assert(not classify())
effect.amount_value=0;effect.is_empty=true
rejects(phrase,'volume_column_visible',false)
local mapped={key_tracking=3,base_note=43,note_range={36,47},looping=true,loop_start=2,loop_end=14}
phrase.mapping=mapped
assert(classify())
local longer=assert(seq.copy_source(source));longer.length=8
assert(not classify_phrase(phrase,longer),"mapped phrase length changes must remain unsupported")
assert(classify(),"unchanged mapped output must remain compatible")
phrase.mapping=nil
for _,update in ipairs({function(s)s.paragraphs={' '}end,function(s)s.paragraphs={'return pattern {}'}end,
 function(s)s.parameters={{name='sentinel',value=23}}end,function(s)s.pending_changes=1 end,
 function(s)s.editor_visible=false end})do
 local original=phrase.script
 phrase.script={paragraphs={},parameters={},pending_changes=0,editor_visible=true}
 update(phrase.script);assert(not classify());phrase.script=original
end
local old=phrase.lines[512].note_columns[12].volume_value
phrase.lines[512].note_columns[12].volume_value=nil
assert(not classify());phrase.lines[512].note_columns[12].volume_value=old
local old_script=phrase.script
phrase.script=setmetatable({},{__index=function()error('script access failed')end})
assert(not classify());phrase.script=old_script
local baseline=assert(ownership.snapshot(phrase))
for _,update in ipairs({function(p)p.base_note=p.base_note+1 end,function(p)p.autoseek=not p.autoseek end,
 function(p)p.column_names[12]='renamed' end,function(p)p.column_mutes[12]=true end,
 function(p)p.visible_note_columns=2 end})do
 local altered=phrase_fixture();apply(altered,planned);update(altered)
 assert(not ownership.compare(baseline,assert(ownership.snapshot(altered))))
end
-- Receiver-dependent output changes block, while unchanged output stays compatible.
local slide=assert(seq.copy_source(source));slide.time_events[2]='N';slide.pitch_events[2].slide=true
local plugin={sample=false,plugin=true,midi=false,alias=false}
local slide_phrase=phrase_fixture();apply(slide_phrase,output(slide,'play_once',plugin))
local plugin_result=assert(classify_phrase(slide_phrase,slide,plugin))
assert(plugin_result.kind=='owned')
assert(not classify_phrase(slide_phrase,slide,sample))
assert(not classify_phrase(slide_phrase,slide,{}))
local foreign=phrase_fixture();instrument.phrases[2]=foreign
local foreign_result,_,foreign_kind=validator.classify(song,instrument,foreign,sample,capacities,options)
assert(not foreign_result and foreign_kind=='foreign');instrument.phrases[2]=nil
local detached=phrase_fixture();detached.name=phrase.name
local detached_result,_,detached_kind=validator.classify(song,instrument,detached,sample,capacities,options)
assert(not detached_result and detached_kind=='unavailable')
local collision=phrase_fixture();collision.name=phrase.name;instrument.phrases[2]=collision
assert(not classify());instrument.phrases[2]=nil
-- Read-only classification never invokes mutation or render methods.
for _,name in ipairs({'clear','copy_from','set_column_name','set_column_is_muted'})do phrase[name]=function()error('unexpected mutation')end end
phrase.script.commit=function()error('unexpected script commit')end
phrase.script.render_to_pattern=function()error('unexpected rendering')end
local raw=song.tool_data
assert(classify())
assert(song.tool_data==raw and ownership.compare(baseline,assert(ownership.snapshot(phrase))))
for _,case in ipairs({{profile=sample,pb=0},{profile=plugin,pb=2}})do
 local current_output=output(slide,'play_once',case.profile,case.pb)
 local current_phrase=phrase_fixture();apply(current_phrase,current_output)
 assert(classify_phrase(current_phrase,slide,case.profile,'play_once',case.pb))
 for key,required in pairs(current_output.required_visibility)do
  if (type(required)=='boolean'and required)or(type(required)=='number'and required>0)then
   local original=current_phrase[key]
   if type(required)=='boolean'then current_phrase[key]=false else current_phrase[key]=required-1 end
   assert(not classify_phrase(current_phrase,slide,case.profile,'play_once',case.pb),key)
   current_phrase[key]=original
  end
 end
end
-- Destination preflight permits widening a clean phrase to the native plan's range.
local destination_output=output(slide,'play_once',plugin,2)
local narrow_destination=assert(ownership.snapshot(phrase_fixture()))
narrow_destination.properties.visible_note_columns=1
narrow_destination.properties.visible_effect_columns=0
for _,key in ipairs({'instrument_column_visible','volume_column_visible',
    'panning_column_visible','delay_column_visible','sample_effects_column_visible'})do
 narrow_destination.properties[key]=false
end
assert(destination_output.required_visibility.visible_note_columns>1 and
 destination_output.required_visibility.visible_effect_columns>0)
local narrow_before=assert(ownership.copy_snapshot(narrow_destination))
assert(validator.preflight_destination(narrow_destination,destination_output),
 'destination preflight must allow the planned note/effect/ancillary expansion')
assert(ownership.compare(narrow_before,narrow_destination),
 'destination preflight must not mutate its captured visibility floor')
local wide_destination=assert(ownership.copy_snapshot(narrow_destination))
wide_destination.properties.visible_note_columns=12
wide_destination.properties.visible_effect_columns=8
for _,key in ipairs({'instrument_column_visible','volume_column_visible',
    'panning_column_visible','delay_column_visible','sample_effects_column_visible'})do
 wide_destination.properties[key]=true
end
assert(validator.preflight_destination(wide_destination,destination_output),
 'destination preflight must preserve a wider existing native visibility floor')
local unsafe_destination=assert(ownership.copy_snapshot(narrow_destination))
unsafe_destination.script.paragraphs[1]='return pattern {}'
assert(not validator.preflight_destination(unsafe_destination,destination_output),
 'destination preflight must continue rejecting script state')
unsafe_destination=assert(ownership.copy_snapshot(narrow_destination))
unsafe_destination.mapping.present=true
unsafe_destination.properties.number_of_lines=destination_output.expected.properties.number_of_lines+1
assert(not validator.preflight_destination(unsafe_destination,destination_output),
 'destination preflight must continue rejecting mapped length changes')
unsafe_destination=assert(ownership.copy_snapshot(narrow_destination))
unsafe_destination.lines[1].notes[3].is_empty=false
unsafe_destination.lines[1].notes[3].note_value=48
assert(not validator.preflight_destination(unsafe_destination,destination_output),
 'destination preflight must continue rejecting data hidden by the visibility expansion')
local readonly=setmetatable({},{__index=phrase,__newindex=function()error('unexpected property write')end})
instrument.phrases[1]=readonly
local readonly_song=setmetatable({},{__index=song,__newindex=function()error('unexpected store write')end})
assert(validator.classify(readonly_song,instrument,readonly,sample,capacities,options))
instrument.phrases[1]=phrase
assert(not validator.classify(song,instrument,phrase,sample,capacities,1))
local poisoned=setmetatable({},{__index=function()error('options access was not rejected')end})
assert(not validator.classify(song,instrument,phrase,sample,capacities,poisoned))
local frozen=assert(classify())
assert(frozen.planning_inputs.capabilities.sample==true and frozen.planning_inputs.capacities.max_lines==512
 and frozen.planning_inputs.options.pitch_bend_delivery==true and frozen.planning_inputs.options.excluded==nil)
options.pitch_bend_delivery=false;capacities.max_lines=500;sample.sample=false
assert(frozen.planning_inputs.options.pitch_bend_delivery==true and frozen.planning_inputs.capacities.max_lines==512
 and frozen.planning_inputs.capabilities.sample==true)
options.pitch_bend_delivery=true;capacities.max_lines=512;sample.sample=true
local function unreferenced_proof()
 local gc_phrase=phrase_fixture();apply(gc_phrase,planned)
 local gc_instrument={name='collectable proof',phrases={gc_phrase}}
 local gc_song={instruments={gc_instrument},tool_data=''}
 assert(store.save(gc_song,1,source,'play_once',0))
 local gc_candidate=assert(validator.classify(gc_song,gc_instrument,gc_phrase,sample,capacities,options))
 local sealed=assert(validator.retained_baseline(gc_candidate.baseline))
 local identity=assert(validator.retained_baseline_identity(sealed))
 return setmetatable({sealed,identity},{__mode='v'})
end
local weak_proof=unreferenced_proof()
for _=1,3 do collectgarbage('collect') end
assert(weak_proof[1]==nil and weak_proof[2]==nil,
 'opaque baseline identities and sealed snapshots must not retain each other after context release')
print('ACID committed output compatibility and field preflight checks passed')



