local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')

local function setup(count)
  local song,instrument,selected,other,source=helper.fixture()
  song.undo_descriptions={}
  function song:describe_undo(description)self.undo_descriptions[#self.undo_descriptions+1]=description end
  local holders={selected}
  for _=1,count-1 do holders[#holders+1]=helper.phrase(source,101) end
  local extra_instruments={}
  for index=2,#holders do
    extra_instruments[index-1]=helper.instrument({holders[index]})
    song.instruments[#song.instruments+1]=extra_instruments[index-1]
  end
  local writer={status='idle',cancels=0}
  function writer:state()return self.status,self.token end
  function writer.is_temporary()return false end
  local log={sinks=0}
  local ctx=context.new{writer=writer,capture=function()error('identity operation captured a musical request')end,
    sink=function()log.sinks=log.sinks+1;return false,'unexpected musical dispatch'end,
    cancel=function()writer.cancels=writer.cancels+1;return true end}
  ctx:attach_document(song);ctx:open_dialog();ctx:bind_phrase(instrument,selected)
  return ctx,song,instrument,selected,other,source,holders,writer,log
end

-- Recovery projections are detached values; copying binds New and restores without consuming its origin.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local outgoing=seq.copy_source(source)
  outgoing.pitch_events[1]=seq.new_pitch(7,0,false,false)
  ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true})
  ctx:transition('edit',{source=outgoing,output_policy='play_once',pb_range=0})
  cache.detach(song,instrument,selected,'collision draft')
  local rows=assert(ctx:recovery_entries())
  assert(#rows==1 and rows[1].labels.instrument=='Sampler' and rows[1].revision)
  local stale=rows[1].revision+1
  assert(not ctx:discard_recovery(rows[1].token,stale),'stale recovery discard was accepted')
  assert(not ctx:copy_recovery_to_new(rows[1].token,stale),'stale recovery copy was accepted')
  assert(ctx:target_state().kind=='owned','stale recovery copy changed the target')
  local copied,metadata=ctx:copy_recovery_to_new(rows[1].token,rows[1].revision)
  assert(copied,metadata)
  assert(ctx:target_state().kind=='new' and rawequal(ctx:target_state().instrument,instrument))
  assert(seq.same_source(ctx:editor_state().source,outgoing))
  local scratch=assert(cache.get(song,instrument,nil,ctx:draft_options()))
  assert(seq.same_source(scratch,outgoing))
  assert(#assert(ctx:recovery_entries())==1,'copy consumed the recovery origin')
  assert(ctx:discard_recovery(rows[1].token,rows[1].revision))
  assert(#assert(ctx:recovery_entries())==0)
end

-- Resolves only the selected holder, clones committed source/settings, and leaves music intact.
do
  local ctx,song,instrument,selected,other,source,holders,_,log=setup(2)
  local before=assert(ownership.snapshot(selected))
  local other_before=assert(ownership.snapshot(holders[2]))
  local unrelated_draft=seq.new_pattern(6)
  assert(store.write_draft(song,instrument,other,unrelated_draft,'play_once',0))
  local raw_before=song.tool_data
  assert(ctx:independence_eligibility())
  local changed,result=ctx:make_independent()
  assert(changed,result)
  assert(result.old_id==101 and result.id==103)
  assert(rawequal(result.phrase,selected) and rawequal(result.instrument,instrument))
  local after=assert(ownership.snapshot(selected))
  assert(ownership.compare(before,after,'name'),'Make Independent changed phrase content')
  assert(ownership.id(selected)==103)
  assert(ownership.compare(other_before,assert(ownership.snapshot(holders[2]))))
  local old_source,old_policy,old_pb=store.read_entry(song,101)
  local new_source,new_policy,new_pb=store.read_entry(song,103)
  local unrelated_source=store.read_draft(song,instrument,other)
  assert(seq.same_source(old_source,source) and seq.same_source(new_source,source))
  assert(old_policy==new_policy and old_pb==new_pb)
  assert(seq.same_source(unrelated_source,unrelated_draft),'unrelated durable draft changed')
  assert(#song.undo_descriptions==1 and song.undo_descriptions[1]=='ACID: Make Independent')
  assert(song.tool_data~=raw_before and #instrument.phrases==2 and #ctx:target_state().phrase.name>0)
  assert(ctx:target_state().kind=='owned' and ctx:editor_state().output_policy==new_policy)
  assert(log.sinks==0,'Make Independent entered the musical scheduler')
end

-- A three-holder collision remains safely blocked until each selected object is resolved.
do
  local ctx,song,_,selected,_,source,holders=setup(3)
  assert(ctx:make_independent())
  assert(ownership.id(selected)==103)
  local groups=assert(ownership.inventory(song))
  assert(#groups[101]==2 and #groups[103]==1)
  ctx:bind_phrase(holders[2] and song.instruments[2],holders[2])
  assert(not ctx:musical_eligibility(),'remaining collision became writable')
  assert(ctx:independence_eligibility())
  local changed,result=ctx:make_independent()
  assert(changed,result)
  assert(result.id==104 and ownership.id(holders[2])==104)
  assert(seq.same_source(assert(store.read_entry(song,104)),source))
end

-- A collision resolved on one instrument preserves its foreign neighbor and
-- any still-colliding holders; the selected third holder is explicit.
do
  local ctx,song,instrument,_,_,source,holders=setup(3)
  local selected=holders[3]
  table.remove(song.instruments,3)
  instrument.phrases[#instrument.phrases+1]=selected
  local foreign=helper.phrase(source,109)
  foreign.name='Unowned native phrase'
  instrument.phrases[#instrument.phrases+1]=foreign
  local first_before=assert(ownership.snapshot(holders[1]))
  local second_before=assert(ownership.snapshot(holders[2]))
  local selected_before=assert(ownership.snapshot(selected))
  ctx:bind_phrase(instrument,selected)
  local changed,result=ctx:make_independent()
  assert(changed,result)
  assert(result.id==103 and ownership.id(selected)==103)
  assert(ownership.compare(selected_before,assert(ownership.snapshot(selected)),'name'))
  assert(ownership.compare(first_before,assert(ownership.snapshot(holders[1])))
    and ownership.compare(second_before,assert(ownership.snapshot(holders[2]))))
  assert(rawequal(instrument.phrases[4],foreign) and foreign.name=='Unowned native phrase')
  assert(seq.same_source(assert(store.read_entry(song,103)),source))
end

-- Missing records, modified group content, busy writers, and stale selection reject without rekeying.
for _,fault in ipairs({'missing_source','corrupt_source','changed_holder','busy_writer','changed_target'}) do
  local ctx,song,instrument,selected,_,_,holders,writer=setup(2)
  if fault=='missing_source' then song.tool_data='' end
  if fault=='corrupt_source' then song.tool_data='invalid ACID store' end
  if fault=='changed_holder' then
    holders[2].lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value=1
    holders[2].name=assert(ownership.make_name(holders[2],101))
  end
  if fault=='busy_writer' then writer.status='busy';writer.token={} end
  if fault=='changed_target' then ctx:bind_phrase(instrument,holders[2]) end
  local names={selected.name,holders[2].name}
  local raw=song.tool_data
  local revisions=ctx:revision_state()
  local changed=ctx:make_independent()
  assert(not changed,fault..' was accepted')
  assert(ownership.compare(revisions,ctx:revision_state()),fault..' changed runtime intent during failed preflight')
  assert(selected.name==names[1] and holders[2].name==names[2],fault..' rekeyed a phrase')
  if fault~='missing_source' then assert(song.tool_data==raw,fault..' changed song data') end
end

-- A holder changed after candidate preparation invalidates the captured guard
-- before either the song store or selected ownership name is written.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local raw,name=song.tool_data,selected.name
  local original=store.prepare
  store.prepare=function(target,id,pattern,policy,pb,guard,...)
    local candidate,reason=original(target,id,pattern,policy,pb,guard,...)
    assert(candidate,reason)
    holders[2].lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value=1
    holders[2].name=assert(ownership.make_name(holders[2],101))
    return candidate
  end
  local changed=ctx:make_independent()
  store.prepare=original
  assert(not changed,'stale prepared collision group was accepted')
  assert(selected.name==name and song.tool_data==raw)
end

-- Allocation skips source entries without a live holder.
do
  local ctx,song,_,selected,_,source=setup(2)
  assert(store.save(song,105,source,'play_once',0))
  local changed,result=ctx:make_independent()
  assert(changed,result)
  assert(result.id==106 and ownership.id(selected)==106)
end

-- A store setter that writes and then throws is guardedly restored with the old identity intact.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local raw=song.tool_data
  local original=store.commit
  store.commit=function(target,candidate)
    assert(original(target,candidate))
    error('injected store failure after write',0)
  end
  local changed=ctx:make_independent()
  store.commit=original
  assert(not changed,'failed store commit was reported as success')
  assert(song.tool_data==raw and ownership.id(selected)==101)
  assert(ownership.id(holders[2])==101 and not ctx:integrity_state().blocked)
end

-- A matching object-local editor draft follows the selected object only after
-- the new committed baseline is verified; an ambiguous old-ID durable draft stays.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local old_draft=seq.new_pattern(6)
  assert(store.write_draft(song,instrument,selected,old_draft,'play_once',0))
  local other_holder=helper.phrase(source,101)
  song.instruments[#song.instruments+1]=helper.instrument({other_holder})
  ctx:bind_phrase(instrument,selected)
  local outgoing=seq.copy_source(source)
  outgoing.pitch_events[1]=seq.new_pitch(11,0,false,false)
  ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true})
  ctx:transition('edit',{source=outgoing,output_policy='play_once',pb_range=0})
  local changed,result=ctx:make_independent()
  assert(changed,result)
  assert(seq.same_source(ctx:editor_state().source,outgoing),
    'Make Independent discarded the selected object-local editor draft')
  local restored=assert(cache.get(song,instrument,selected,ctx:draft_options()))
  assert(seq.same_source(restored,outgoing),'matching draft was not rebound to the new ID')
  local old_saved=assert(store.read_draft(song,song.instruments[2],other_holder))
  assert(seq.same_source(old_saved,old_draft),
    'Make Independent consumed the ambiguous old-ID durable draft')
  assert(result.old_id==101 and ownership.id(selected)==result.id)
end

-- Failure after the ownership name changes rolls both metadata writes back exactly.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local raw,name= song.tool_data,selected.name
  local original=store.read_entry
  store.read_entry=function(target,id,...)
    if id==103 then return nil,'injected clone verification failure' end
    return original(target,id,...)
  end
  local changed=ctx:make_independent()
  store.read_entry=original
  assert(not changed,'unverified clone was committed')
  assert(song.tool_data==raw and selected.name==name and ownership.id(holders[2])==101)
  assert(not ctx:integrity_state().blocked)
end

-- A name setter that writes the new seal and then throws is restored exactly.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local original_name=selected.name
  local old_meta=getmetatable(selected)
  local backing=original_name
  rawset(selected,'name',nil)
  setmetatable(selected,{__eq=old_meta.__eq,
    __index=function(object,key)
      if key=='name' then return backing end
      return old_meta.__index and old_meta.__index(object,key) or nil
    end,
    __newindex=function(object,key,value)
      if key=='name' then
        backing=value
        if value~=original_name then error('name setter failed after write',0) end
      else rawset(object,key,value) end
    end})
  local changed=ctx:make_independent()
  assert(not changed,'write-then-throw name setter was reported as success')
  assert(selected.name==original_name and ownership.id(holders[2])==101)
  assert(not ctx:integrity_state().blocked,'verified name rollback blocked the document')
end

-- A reentrant musical change during verification is never overwritten by
-- rollback; because full restoration cannot be proved, the runtime is blocked.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local raw=song.tool_data
  local original_read=store.read_entry
  store.read_entry=function(target,id,...)
    if id==103 then
      selected.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value=1
      return nil,'injected verification failure after external phrase change'
    end
    return original_read(target,id,...)
  end
  local changed=ctx:make_independent()
  store.read_entry=original_read
  assert(not changed,'externally changed phrase was reported as independent')
  assert(song.tool_data==raw and ownership.id(selected)==101)
  assert(selected.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value==1,
    'rollback overwrote the reentrant phrase change')
  assert(ownership.id(holders[2])==101 and ctx:integrity_state().blocked,
    'unverified phrase rollback did not block the runtime')
end

-- A refused name rollback leaves the new seal visible and blocks further writes
-- instead of claiming that identity was restored.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local original_name=selected.name
  local old_meta=getmetatable(selected)
  local backing=original_name
  rawset(selected,'name',nil)
  setmetatable(selected,{__eq=old_meta.__eq,
    __index=function(object,key)
      if key=='name' then return backing end
      return old_meta.__index and old_meta.__index(object,key) or nil
    end,
    __newindex=function(object,key,value)
      if key=='name' then
        if value==original_name then error('name rollback refused',0) end
        backing=value
      else rawset(object,key,value) end
    end})
  local original_read=store.read_entry
  store.read_entry=function(target,id,...)
    if id==103 then return nil,'injected clone verification failure' end
    return original_read(target,id,...)
  end
  local changed=ctx:make_independent()
  store.read_entry=original_read
  assert(not changed,'failed name rollback was reported as success')
  assert(ownership.id(selected)==103 and ownership.id(holders[2])==101)
  assert(ctx:integrity_state().blocked,'unverified name rollback did not block the document')
end

print('ACID runtime Make Independent transaction passed')
