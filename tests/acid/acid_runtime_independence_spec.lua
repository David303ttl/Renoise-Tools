local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local MAX_FULL_PROOFS_PER_RESOLUTION=2
local CHANGED_RECEIVER_CHANNEL=2

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

-- Receiver changes during the guarded mutation window invalidate the captured
-- capability proof before the song store or phrase name can commit.
do
  local ctx,song,instrument,selected,_,_,holders=setup(2)
  local raw,name=song.tool_data,selected.name
  local snapshots={assert(ownership.snapshot(selected)),assert(ownership.snapshot(holders[2]))}
  song.describe_undo=function()
    instrument.midi_output_properties.channel=2
  end
  local changed=ctx:make_independent()
  assert(not changed,'receiver profile drift during mutation was accepted')
  assert(song.tool_data==raw and selected.name==name,
    'receiver profile drift committed source or ownership metadata')
  assert(instrument.midi_output_properties.channel==2,
    'receiver profile rollback overwrote an external change')
  assert(ownership.compare(snapshots[1],assert(ownership.snapshot(selected))) and
    ownership.compare(snapshots[2],assert(ownership.snapshot(holders[2]))),
    'receiver profile drift changed phrase content')
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

-- Collision eligibility accepts complete matching groups and treats every
-- phrase as a separate object even when native equality compares contents.
for _,count in ipairs({2,3}) do
  local ctx,song,_,selected,_,source,holders=setup(1)
  local draft=seq.new_pattern(6)
  assert(store.write_draft(song,song.instruments[1],selected,draft,'play_once',0))
  for index=2,count do
    local instrument=helper.instrument({helper.phrase(source,101)})
    song.instruments[#song.instruments+1]=instrument
    holders[index]=instrument.phrases[1]
  end
  local raw=song.tool_data
  local snapshots={}
  for index=1,count do snapshots[index]=assert(ownership.snapshot(holders[index])) end
  local eligible,reason=ctx:independence_eligibility()
  assert(eligible,reason)
  assert(song.tool_data==raw,'read-only collision eligibility changed source or draft bytes')
  for index=1,count do
    assert(ownership.compare(snapshots[index],assert(ownership.snapshot(holders[index]))),
      'read-only collision eligibility changed a holder')
  end
end

-- Valid seals do not make unlike complete snapshots or receivers compatible.
for _,fault in ipairs({'different_seal','hidden_tail','metadata','incompatible_holder',
    'phrase_getter','receiver_getter','phrase_api_getter','missing_source'}) do
  local ctx,song,instrument,selected,_,source=setup(1)
  local draft=seq.new_pattern(6)
  assert(store.write_draft(song,instrument,selected,draft,'play_once',0))
  local other_instrument=helper.instrument({helper.phrase(source,101)})
  local other=other_instrument.phrases[1]
  song.instruments[#song.instruments+1]=other_instrument
  local selected_snapshot,other_snapshot
  local restore_fault
  if fault=='different_seal' then
    other.lines[1].note_columns[1].note_value=61
    other.lines[1].note_columns[1].is_empty=false
    other.name=assert(ownership.make_name(other,101))
  elseif fault=='hidden_tail' then
    local cell=other.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns]
    cell.instrument_value=1;cell.is_empty=false
    other.name=assert(ownership.make_name(other,101))
  elseif fault=='metadata' then
    other.column_names[1]='different protected mapping name'
    other.name=assert(ownership.make_name(other,101))
  elseif fault=='incompatible_holder' then
    other.number_of_lines=source.length+1
    other.name=assert(ownership.make_name(other,101))
  elseif fault=='phrase_getter' then
    selected_snapshot=assert(ownership.snapshot(selected))
    other_snapshot=assert(ownership.snapshot(other))
    local loop_start,old_meta=other.loop_start,getmetatable(other)
    other.loop_start=nil
    setmetatable(other,{__index=function(_,key)
      if key=='loop_start' then error('phrase getter failed') end
    end})
    restore_fault=function()
      setmetatable(other,old_meta);other.loop_start=loop_start
    end
  elseif fault=='receiver_getter' then
    other_instrument.samples=nil
    setmetatable(other_instrument,{__index=function(_,key)
      if key=='samples' then error('receiver getter failed') end
    end})
  elseif fault=='phrase_api_getter' then
    local api=renoise.InstrumentPhrase
    local old_limit,old_meta=api.MAX_NUMBER_OF_LINES,getmetatable(api)
    selected_snapshot=assert(ownership.snapshot(selected))
    other_snapshot=assert(ownership.snapshot(other))
    rawset(api,'MAX_NUMBER_OF_LINES',nil)
    setmetatable(api,{__index=function(_,key)
      if key=='MAX_NUMBER_OF_LINES' then error('phrase API getter failed') end
    end})
    restore_fault=function()
      setmetatable(api,old_meta);rawset(api,'MAX_NUMBER_OF_LINES',old_limit)
    end
  elseif fault=='missing_source' then
    song.tool_data=''
  end
  selected_snapshot=selected_snapshot or assert(ownership.snapshot(selected))
  other_snapshot=other_snapshot or assert(ownership.snapshot(other))
  local raw=song.tool_data
  local names={selected.name,other.name}
  local rejected=ctx:independence_eligibility()
  if restore_fault then restore_fault() end
  assert(not rejected,fault..' collision was eligible')
  assert(song.tool_data==raw,fault..' eligibility changed source or durable draft bytes')
  assert(selected.name==names[1] and other.name==names[2],fault..' eligibility changed ownership names')
  assert(ownership.compare(selected_snapshot,assert(ownership.snapshot(selected))),
    fault..' eligibility changed the selected phrase')
  assert(ownership.compare(other_snapshot,assert(ownership.snapshot(other))),
    fault..' eligibility changed the colliding phrase')
end

-- One full context proof and one independent executor admission are sufficient
-- for a successful two- or three-holder resolution.
for _,count in ipairs({2,3}) do
  local ctx=setup(count)
  local eligibility=require('runtime.eligibility')
  local original=eligibility.independence
  local constructions=0
  eligibility.independence=function(...)
    constructions=constructions+1
    return original(...)
  end
  local changed,result=ctx:make_independent()
  eligibility.independence=original
  assert(changed,result)
  assert(constructions<=MAX_FULL_PROOFS_PER_RESOLUTION,
    'Make Independent constructed more than two full eligibility proofs')
end

-- Context authorization pins the initial source, holder snapshots and receiver
-- profiles through the executor admission boundary.
for _,fault in ipairs({'source','content','profile'}) do
  local ctx,song,instrument,selected,_,source=setup(1)
  local other_instrument=helper.instrument({helper.phrase(source,101)})
  local other=other_instrument.phrases[1]
  song.instruments[#song.instruments+1]=other_instrument
  local raw,name=song.tool_data,selected.name
  local selected_before=assert(ownership.snapshot(selected))
  local executor=require('runtime.independence')
  local original=executor.run
  executor.run=function(...)
    if fault=='source' then
      local changed_source=seq.copy_source(source)
      changed_source.pitch_events[1]=seq.new_pitch(12,0,false,false)
      assert(store.save(song,101,changed_source,'play_once',0))
    elseif fault=='content' then
      other.column_names[1]='external content change before executor admission'
      other.name=assert(ownership.make_name(other,101))
    else
      other_instrument.midi_output_properties.channel=CHANGED_RECEIVER_CHANNEL
    end
    return original(...)
  end
  local changed=ctx:make_independent()
  executor.run=original
  assert(not changed,fault..' drift was accepted as a new executor baseline')
  assert(selected.name==name,'executor admission drift rekeyed the selected phrase')
  assert(ownership.compare(selected_before,assert(ownership.snapshot(selected))),
    'executor admission drift changed selected phrase content')
  if fault=='source' then
    local committed=assert(store.read_entry(song,101))
    assert(not seq.same_source(committed,source),'executor admission rollback overwrote external source drift')
  elseif fault=='content' then
    assert(other.column_names[1]=='external content change before executor admission',
      'executor admission rollback overwrote external holder drift')
  else
    assert(other_instrument.midi_output_properties.channel==CHANGED_RECEIVER_CHANNEL,
      'executor admission rollback overwrote external receiver drift')
  end
  if fault~='source' then
    assert(song.tool_data==raw,'executor admission drift changed durable source data')
  end
end

-- Make Independent owns its admission window before any eligibility callback
-- can reenter, change runtime intent, or replace the open document session.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  assert(store.write_draft(song,instrument,selected,seq.new_pattern(6),'play_once',0))
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local raw,name=song.tool_data,selected.name
  local original=ctx.independence_eligibility
  local nested_result,nested_reason
  local injected=false
  ctx.independence_eligibility=function(self,...)
    if not injected then
      injected=true
      nested_result,nested_reason=self:make_independent()
    end
    return original(self,...)
  end
  local changed,result=ctx:make_independent()
  ctx.independence_eligibility=original
  assert(changed,result)
  assert(nested_result==false and nested_reason,
    'reentrant Make Independent was not refused during initial eligibility')
  assert(ownership.id(selected)~=101 and #song.undo_descriptions==1,
    'reentrant admission caused a duplicate identity transaction')
  assert(name~=selected.name and song.tool_data~=raw)
end

-- Reopening the dialog on the attached document during initial eligibility
-- invalidates its session token instead of authorizing against the new one.
do
  local ctx,song,_,selected,_,source=setup(1)
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local raw,name=song.tool_data,selected.name
  local original=ctx.independence_eligibility
  local injected=false
  ctx.independence_eligibility=function(self,...)
    if not injected then
      injected=true
      self:close_dialog()
      self:open_dialog()
    end
    return original(self,...)
  end
  local changed=ctx:make_independent()
  ctx.independence_eligibility=original
  assert(not changed,'same-song session replacement was accepted during admission')
  assert(song.tool_data==raw and selected.name==name and #song.undo_descriptions==0,
    'stale session admission changed committed data or ownership')
end

-- Reattaching the same song creates a new document epoch and invalidates the
-- original admission, even though its object identities and bytes still match.
do
  local ctx,song,_,selected,_,source=setup(1)
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local raw,name=song.tool_data,selected.name
  local original=ctx.independence_eligibility
  local injected=false
  ctx.independence_eligibility=function(self,...)
    if not injected then
      injected=true
      self:release_document()
      self:attach_document(song)
      self:open_dialog()
    end
    return original(self,...)
  end
  local changed=ctx:make_independent()
  ctx.independence_eligibility=original
  assert(not changed,'same-song document reattachment was accepted during admission')
  assert(song.tool_data==raw and selected.name==name and #song.undo_descriptions==0,
    'stale document epoch changed committed data or ownership')
end

-- Native song replacement rejects before querying the old song's undo state.
do
  local ctx,song,_,selected=setup(2)
  local raw,name=song.tool_data,selected.name
  local original_current=renoise.song
  local original_eligibility=ctx.independence_eligibility
  local undo_reads,reads_before_change=0,nil
  song.is_undo_redoing=function()undo_reads=undo_reads+1;return false end
  ctx.independence_eligibility=function(self,...)
    local proof,reason=original_eligibility(self,...)
    reads_before_change=undo_reads
    local replacement={}
    renoise.song=function()return replacement end
    return proof,reason
  end
  local changed=ctx:make_independent()
  renoise.song=original_current
  ctx.independence_eligibility=original_eligibility
  assert(not changed,'a different native current song retained identity authorization')
  assert(undo_reads==reads_before_change,'stale admission inspected undo state on the old song')
  assert(song.tool_data==raw and selected.name==name,
    'native song replacement changed the old ownership or store')
end

-- Target revisions retain navigation history even when the final objects match.
do
  local ctx,song,instrument,selected,other,source=setup(2)
  local raw,name=song.tool_data,selected.name
  local original=ctx.transition
  local injected=false
  ctx.transition=function(self,kind,...)
    if kind=='independence' and not injected then
      injected=true
      self:bind_phrase(instrument,other)
      self:bind_phrase(instrument,selected)
    end
    return original(self,kind,...)
  end
  local changed=ctx:make_independent()
  ctx.transition=original
  assert(not changed,'A-to-B-to-A target drift regained admission authorization')
  assert(song.tool_data==raw and selected.name==name and #song.undo_descriptions==0,
    'target revision drift changed committed data or ownership')
end

-- Native undo starting in the undo-description callback invalidates the
-- commit window before either the source record or phrase seal can be written.
do
  local ctx,song,_,selected,other,source=setup(2)
  local raw,name=song.tool_data,selected.name
  local other_name=other.name
  local descriptions=0
  local undo_processing=false
  song.is_undo_redoing=function()return undo_processing end
  song.describe_undo=function()
    descriptions=descriptions+1
    undo_processing=true
  end
  local changed=ctx:make_independent()
  assert(not changed,'commit-window native undo processing was accepted')
  assert(descriptions==1 and song.tool_data==raw and selected.name==name,
    'commit-window drift changed source bytes or selected ownership')
  assert(other.name==other_name,'commit-window drift changed the other phrase seal')
end

-- Writer occupancy changing after initial proof admission rejects the action
-- without cancellation or an automatic retry; a new explicit call can proceed.
do
  local ctx,song,_,selected,_,_,_,writer=setup(2)
  local raw,name=song.tool_data,selected.name
  local cancels=writer.cancels
  local original_eligibility=ctx.independence_eligibility
  local injected=false
  ctx.independence_eligibility=function(self,...)
    local proof,reason=original_eligibility(self,...)
    if proof and not injected then
      injected=true
      writer.status='busy';writer.token={}
    end
    return proof,reason
  end
  local executor=require('runtime.independence')
  local original_run=executor.run
  local admissions=0
  executor.run=function(...)
    admissions=admissions+1
    return original_run(...)
  end
  local changed=ctx:make_independent()
  assert(not changed,'writer occupancy drift after initial proof was accepted')
  assert(admissions==0,'busy writer crossed the context admission guard')
  assert(writer.status=='busy' and writer.cancels==cancels,
    'admission canceled or released the newly busy writer')
  assert(song.tool_data==raw and selected.name==name,
    'busy writer admission changed source bytes or phrase ownership')
  writer.status='idle';writer.token=nil
  local retried,retry_result=ctx:make_independent()
  ctx.independence_eligibility=original_eligibility
  executor.run=original_run
  assert(retried,retry_result)
  assert(admissions==1,'explicit idle retry did not make exactly one new admission')
end

-- Writer occupancy changing inside the undo-description callback is caught by
-- the commit guard before the source store or phrase name can be written.
do
  local ctx,song,_,selected,_,_,_,writer=setup(2)
  local raw,name=song.tool_data,selected.name
  local bytes,write_attempts=raw,0
  rawset(song,'tool_data',nil)
  setmetatable(song,{
    __index=function(_,key)if key=='tool_data' then return bytes end end,
    __newindex=function(object,key,value)
      if key=='tool_data' then bytes=value;write_attempts=write_attempts+1
      else rawset(object,key,value) end
    end,
  })
  local cancels=writer.cancels
  local described=0
  song.describe_undo=function()
    described=described+1
    if described==1 then writer.status='busy';writer.token={} end
  end
  local executor=require('runtime.independence')
  local original_run=executor.run
  local admissions=0
  executor.run=function(...)
    admissions=admissions+1
    return original_run(...)
  end
  local changed=ctx:make_independent()
  assert(not changed,'writer occupancy drift in the commit window was accepted')
  assert(described==1 and admissions==1,'busy commit window caused an implicit identity retry')
  assert(writer.status=='busy' and writer.cancels==cancels,
    'commit guard canceled or released the newly busy writer')
  assert(song.tool_data==raw and selected.name==name,
    'busy commit guard changed source bytes or phrase ownership')
  assert(write_attempts==0,'busy commit guard attempted a source write before rejecting')
  writer.status='idle';writer.token=nil
  local retried,retry_result=ctx:make_independent()
  executor.run=original_run
  assert(retried,retry_result)
  assert(admissions==2 and described==2,
    'explicit idle retry did not make exactly one new transaction')
end

-- An edit revision change during eligibility invalidates admission and leaves
-- the persisted object draft untouched.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local draft=seq.new_pattern(6)
  assert(store.write_draft(song,instrument,selected,draft,'play_once',0))
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local raw,name=song.tool_data,selected.name
  local edited=seq.copy_source(source)
  edited.pitch_events[1]=seq.new_pitch(8,0,false,false)
  local original=ctx.independence_eligibility
  local injected=false
  ctx.independence_eligibility=function(self,...)
    if not injected then
      injected=true
      assert(self:transition('edit',{source=edited,output_policy='play_once',pb_range=0}))
    end
    return original(self,...)
  end
  local changed=ctx:make_independent()
  ctx.independence_eligibility=original
  assert(not changed,'edit revision drift was accepted during admission')
  assert(song.tool_data==raw and selected.name==name and #song.undo_descriptions==0,
    'edit revision drift changed committed data, draft bytes, or ownership')
  assert(song.tool_data==raw,'edit revision drift changed durable draft bytes')
end

-- A callback failure during initial proof admission is returned cleanly and
-- releases the identity lock so a later, valid attempt can proceed.
do
  local ctx,song,_,selected,_,source=setup(1)
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local original=ctx.independence_eligibility
  local calls=0
  ctx.independence_eligibility=function(self,...)
    calls=calls+1
    if calls==1 then error('injected initial proof failure',0) end
    return original(self,...)
  end
  local first=ctx:make_independent()
  assert(not first,'failed initial proof was accepted')
  local changed,result=ctx:make_independent()
  ctx.independence_eligibility=original
  assert(changed,result)
end

-- Replacing the selected phrase at its original instrument index invalidates
-- admission even when the replacement has identical raw contents and seal.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local raw,name=song.tool_data,selected.name
  local original=ctx.independence_eligibility
  local injected=false
  ctx.independence_eligibility=function(self,...)
    if not injected then
      injected=true
      local index
      for position,phrase in ipairs(instrument.phrases) do
        if rawequal(phrase,selected) then index=position;break end
      end
      assert(index,'selected phrase disappeared before injection')
      instrument.phrases[index]=helper.phrase(source,101)
    end
    return original(self,...)
  end
  local changed=ctx:make_independent()
  ctx.independence_eligibility=original
  assert(not changed,'same-index phrase replacement was accepted during admission')
  assert(song.tool_data==raw and selected.name==name and #song.undo_descriptions==0,
    'same-index replacement changed committed data or the detached phrase name')
end

-- Eligibility rejects unavailable, processing, and throwing native undo
-- state before preserving drafts or entering the identity transaction.
for _,fault in ipairs({'unavailable','processing','throwing'}) do
  local ctx,song,_,selected,_,source=setup(1)
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local raw,name=song.tool_data,selected.name
  if fault=='unavailable' then
    song.is_undo_redoing=nil
  elseif fault=='processing' then
    song.is_undo_redoing=function()return true end
  else
    song.is_undo_redoing=function()error('injected native undo state failure',0)end
  end
  local changed=ctx:make_independent()
  assert(not changed,fault..' native undo state was accepted')
  assert(song.tool_data==raw and selected.name==name and #song.undo_descriptions==0,
    fault..' undo state changed committed data or ownership')
end

-- A later receiver inspection that changes the committed source invalidates
-- the whole proof, even though earlier holders already passed compatibility.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local other_instrument=helper.instrument({helper.phrase(source,101)})
  song.instruments[#song.instruments+1]=other_instrument
  local other=other_instrument.phrases[1]
  local before={assert(ownership.snapshot(selected)),assert(ownership.snapshot(other))}
  local capabilities=require('renoise.target_capabilities')
  local original=capabilities.inspect
  local injected_bytes
  capabilities.inspect=function(target)
    local profile,reason=original(target)
    if rawequal(target,other_instrument) then
      local changed_source=seq.copy_source(source)
      changed_source.pitch_events[1]=seq.new_pitch(12,0,false,false)
      assert(store.save(song,101,changed_source,'play_once',0))
      injected_bytes=song.tool_data
    end
    return profile,reason
  end
  local eligible=ctx:independence_eligibility()
  capabilities.inspect=original
  assert(not eligible,'eligibility accepted a source changed during later-holder inspection')
  assert(song.tool_data==injected_bytes,'eligibility overwrote or further changed external source data')
  assert(ownership.compare(before[1],assert(ownership.snapshot(selected))) and
    ownership.compare(before[2],assert(ownership.snapshot(other))),
    'eligibility changed phrase data while rejecting source drift')
end

-- Imported copies with matching names but no local source record cannot enter
-- the transaction; unrelated committed data and a durable scratch draft stay exact.
do
  local song,instrument,_,_,source=helper.fixture('new')
  local selected=helper.phrase(source,101)
  local imported=helper.phrase(source,101)
  local unrelated=helper.phrase(source,200)
  instrument.phrases={selected}
  local imported_instrument=helper.instrument({imported,unrelated})
  song.instruments[#song.instruments+1]=imported_instrument
  assert(store.save(song,200,source,'repeat',12))
  local draft=seq.new_pattern(6)
  assert(store.write_draft(song,imported_instrument,unrelated,draft,'play_once',0))
  local raw=song.tool_data
  local selected_before=assert(ownership.snapshot(selected))
  local imported_before=assert(ownership.snapshot(imported))
  local mutations=0
  local changed=require('runtime.independence').run(song,
    {instrument=instrument,phrase=selected},{
      guard=function()return true end,
      mutate=function(action)mutations=mutations+1;return action()end,
    })
  assert(not changed,'source-less imported collision entered the identity transaction')
  assert(mutations==0,'source-less imported collision entered the mutation scope')
  assert(song.tool_data==raw,'source-less rejection changed unrelated source or durable draft')
  assert(ownership.compare(selected_before,assert(ownership.snapshot(selected))) and
    ownership.compare(imported_before,assert(ownership.snapshot(imported))),
    'source-less rejection changed imported phrase content')
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

-- A durably saved draft survives a context restart and follows the selected
-- object when a later ownership collision requires Make Independent.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local outgoing=assert(seq.copy_source(source))
  outgoing.pitch_events[1]=seq.new_pitch(9,0,false,false)
  assert(ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true}))
  assert(ctx:transition('edit',{source=outgoing,output_policy='play_once',pb_range=0}))
  ctx:release_document()
  local reopened=helper.runtime(song)
  local restored=assert(reopened:restore_editor_target(instrument,selected))
  assert(restored.draft and seq.same_source(restored.source,outgoing))
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local changed,result=reopened:make_independent()
  assert(changed,result)
  assert(seq.same_source(reopened:editor_state().source,outgoing),
    'Make Independent lost the draft restored from durable storage')
  assert(seq.same_source(assert(cache.get(song,instrument,selected,reopened:draft_options())),outgoing))
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
