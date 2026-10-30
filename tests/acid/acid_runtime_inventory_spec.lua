local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local ownership=require('renoise.phrase_ownership')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local fixture,phrase,instrument,runtime=helper.fixture,helper.phrase,helper.instrument,helper.runtime

-- Real classifier proofs establish detached baselines; identical content is not identity.
do
 local song,inst,a,b,source=fixture()
 local ctx=runtime(song,b)
 local target=ctx:bind_phrase(inst,a)
 assert(target.kind=='owned' and rawequal(target.phrase,a),tostring(target.reason))
 assert(target.baseline.id==101 and seq.same_source(target.baseline.source,source))
 target.baseline.source.length=8;target.baseline.settings.pb_range=24
 target.baseline.snapshot.properties.lpb=1
 target.baseline.planning_inputs.capacities.max_lines=1
 target.baseline.planning_inputs.capabilities.sample=false
 local pristine=ctx:target_state()
 assert(pristine.baseline.source.length==4 and pristine.baseline.settings.pb_range==0)
 assert(pristine.baseline.snapshot.properties.lpb~=1)
 assert(pristine.baseline.planning_inputs.capacities.max_lines==512)
 assert(pristine.baseline.planning_inputs.capabilities.sample==true)
 local choices=assert(ctx:phrase_choices(inst))
 for _,choice in ipairs(choices)do assert(not rawequal(choice.phrase,b))end
 assert(cache.put(song,inst,a,seq.new_pattern(5),'play_once',0,ctx:draft_options()))
 assert(cache.put(song,inst,b,seq.new_pattern(6),'play_once',0,ctx:draft_options()))
 assert(cache.get(song,inst,a,ctx:draft_options()).length==5)
 assert(cache.get(song,inst,b,ctx:draft_options()).length==6)
 inst.phrases={b,a};inst.name='Renamed';a.name=a.name
 assert(ctx:refresh_inventory().phrase_index==2)
 assert(rawequal(ctx:target_state().phrase,a))
 local replacement=phrase(source,103)
 inst.phrases={b,replacement}
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(rawequal(ctx:target_state().phrase,a))
 assert(ctx:bind_new(inst).kind=='new')
 song.selected_phrase=b;song.selected_instrument=inst
 assert(ctx:refresh_inventory().kind=='new')
 assert(ctx:bind_phrase(inst,nil).kind=='unavailable')
 assert(helper.eq_calls()==0,'inventory/drafts must use raw phrase identity')
end

-- Even a newly valid source/output pair cannot replace an established session baseline.
do
 local song,inst,a,_,source=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
 local replacement=phrase(changed,101)
 for key,value in pairs(replacement)do a[key]=value end
 assert(store.save(song,101,changed,'play_once',0))
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(ctx:bind_phrase(inst,a).kind=='unavailable')
 -- A cold wrapper gets a fresh proof from persisted data, with no old index/session.
 local cold_phrase=phrase(changed,101)
 local cold_inst=instrument({cold_phrase})
 local cold_song={tool_data=song.tool_data,instruments={cold_inst}}
 local before=cold_song.tool_data
 local cold=runtime(cold_song)
 local classified=cold:bind_phrase(cold_inst,cold_phrase)
 assert(classified.kind=='owned' and seq.same_source(classified.baseline.source,changed))
 assert(cold_song.tool_data==before and #cold_inst.phrases==1)
end

-- Negative persisted fixtures stay blocked and never become implicit New.
for _,fault in ipairs({'missing','corrupt','incompatible','content','collision','inaccessible','foreign'})do
 local song,inst,a,_,source=fixture()
 if fault=='missing' then song.tool_data=''
 elseif fault=='corrupt' then song.tool_data='invalid ACID store'
 elseif fault=='incompatible' then
  local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
  assert(store.save(song,101,changed,'play_once',0))
 elseif fault=='content' then a.lines[512].note_columns[12].delay_value=1
 elseif fault=='collision' then song.instruments[2]=instrument({phrase(source,101)})
 elseif fault=='inaccessible' then a.script=setmetatable({},{__index=function()error('unreadable script')end})
 elseif fault=='foreign' then a.name='Native phrase' end
 local before=song.tool_data
 local target=runtime(song):bind_phrase(inst,a)
 assert(target.kind==(fault=='foreign' and 'foreign' or 'unavailable'),fault)
 assert(type(target.reason)=='string' and #target.reason>0,fault..' needs a concrete reason')
 assert(song.tool_data==before and #inst.phrases==2)
end

-- Instrument removal and changed receiver planning inputs revoke the saved proof.
do
 local song,inst,a=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 inst.plugin_properties.plugin_loaded=true
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(ctx:bind_new(inst).kind=='new')
 song.instruments={instrument({})}
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(rawequal(ctx:target_state().instrument,inst))
end

-- A retained draft validator cannot keep the released document alive or prove it current.
do
 local song,inst,a=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 local options=ctx:draft_options()
 assert(options.validate(song,inst,a))
 ctx:release_document()
 assert(not options.validate(song,inst,a))
 local next_song,next_inst,next_phrase=fixture()
 ctx:attach_document(next_song)
 assert(not options.validate(song,inst,a))
 assert(options.validate(next_song,next_inst,next_phrase))
end

-- Hiding a temporary from UI choices never hides its copied ID from ownership inventory.
do
 local song,inst,a,_,source=fixture()
 local temporary=phrase(source,101)
 local other=instrument({temporary})
 song.instruments[2]=other
 local ctx=runtime(song,temporary)
 assert(ctx:bind_phrase(inst,a).kind=='unavailable')
 assert(#assert(ctx:phrase_choices(other))==1)
 assert(not ctx:draft_options().validate(song,inst,a))
end
print('ACID runtime object inventory and baseline projection passed')


