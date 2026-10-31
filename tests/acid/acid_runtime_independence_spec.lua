local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local MAX_FULL_PROOFS_PER_RESOLUTION=2
local CHANGED_RECEIVER_CHANNEL=2
local UNEXPECTED_COMMITTED_ID=1000
local INDEPENDENCE_COLLISION_ID=101

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
  local integrity_module=require('runtime.integrity')
  local original_new=integrity_module.new
  local mutation_captures=0
  integrity_module.new=function(...)
    local owner=original_new(...)
    local original_capture=owner.capture_mutation
    owner.capture_mutation=function(self,...)
      mutation_captures=mutation_captures+1
      return original_capture(self,...)
    end
    return owner
  end
  local ctx,song,instrument,selected,other,source,holders,_,log=setup(2)
  integrity_module.new=original_new
  local before=assert(ownership.snapshot(selected))
  local other_before=assert(ownership.snapshot(holders[2]))
  local unrelated_draft=seq.new_pattern(6)
  assert(store.write_draft(song,instrument,other,unrelated_draft,'play_once',0))
  local new_phrase_draft=seq.new_pattern(6)
  local scratch_instrument=helper.instrument({})
  scratch_instrument.name='Scratch'
  song.instruments[#song.instruments+1]=scratch_instrument
  assert(store.write_draft(song,scratch_instrument,nil,new_phrase_draft,'repeat',12))
  local raw_before=song.tool_data
  assert(ctx:independence_eligibility())
  local changed,result=ctx:make_independent()
  assert(changed,result)
  assert(mutation_captures==1,'Make Independent captured whole-song recovery evidence more than once')
  assert(result.old_id==101 and result.id==103)
  assert(rawequal(result.phrase,selected) and rawequal(result.instrument,instrument))
  local after=assert(ownership.snapshot(selected))
  assert(ownership.compare(before,after,'name'),'Make Independent changed phrase content')
  assert(ownership.id(selected)==103)
  assert(ownership.compare(other_before,assert(ownership.snapshot(holders[2]))))
  local old_source,old_policy,old_pb=store.read_entry(song,101)
  local new_source,new_policy,new_pb=store.read_entry(song,103)
  local unrelated_source=store.read_draft(song,instrument,other)
  local preserved_new_draft=store.read_draft(song,scratch_instrument,nil)
  assert(seq.same_source(old_source,source) and seq.same_source(new_source,source))
  assert(old_policy==new_policy and old_pb==new_pb)
  assert(seq.same_source(unrelated_source,unrelated_draft),'unrelated durable draft changed')
  assert(seq.same_source(preserved_new_draft,new_phrase_draft),'New phrase durable draft changed')
  assert(#song.undo_descriptions==1 and song.undo_descriptions[1]=='ACID: Make Independent')
  assert(song.tool_data~=raw_before and #instrument.phrases==2 and #ctx:target_state().phrase.name>0)
  assert(ctx:target_state().kind=='owned' and ctx:editor_state().output_policy==new_policy)
  assert(log.sinks==0,'Make Independent entered the musical scheduler')
end

-- An unexpected committed source entry invalidates the identity commit.
do
  local ctx,song,_,selected,_,source=setup(2)
  local raw,name=song.tool_data,selected.name
  local original=store.read
  store.read=function(target,...)
    local entries,reason=original(target,...)
    if entries and target.tool_data~=raw then
      entries[UNEXPECTED_COMMITTED_ID]=assert(ownership.copy_snapshot(source))
    end
    return entries,reason
  end
  local changed=ctx:make_independent()
  store.read=original
  assert(not changed,'unexpected source entry was accepted')
  assert(song.tool_data==raw and selected.name==name,
    'unexpected source entry changed committed data or ownership')
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
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,INDEPENDENCE_COLLISION_ID)})
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
  local ctx,song,instrument,selected,_,source=setup(1)
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
  local ctx,song,instrument,selected,_,source=setup(1)
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

-- Writer occupancy changing during the candidate guard's final allocation
-- check rejects before any source or ownership write and never retries.
do
  local ctx,song,_,selected,_,_,_,writer=setup(2)
  local original_raw,original_name=song.tool_data,selected.name
  local source_bytes,source_write_attempts=original_raw,0
  local old_song_meta=getmetatable(song)
  rawset(song,'tool_data',nil)
  setmetatable(song,{
    __index=function(_,key)if key=='tool_data' then return source_bytes end end,
    __newindex=function(object,key,value)
      if key=='tool_data' then
        source_bytes=value
        source_write_attempts=source_write_attempts+1
      else
        rawset(object,key,value)
      end
    end,
  })
  local name,old_phrase_meta=original_name,getmetatable(selected)
  local name_write_attempts=0
  rawset(selected,'name',nil)
  setmetatable(selected,{
    __index=function(object,key)
      if key=='name' then return name end
      if type(old_phrase_meta)=='table' then
        local index=old_phrase_meta.__index
        if type(index)=='function' then return index(object,key) end
        if type(index)=='table' then return index[key] end
      end
      return nil
    end,
    __newindex=function(object,key,value)
      if key=='name' then
        name_write_attempts=name_write_attempts+1
        name=value
      else
        rawset(object,key,value)
      end
    end,
  })
  local original_prepare,original_allocate=store.prepare,store.allocate
  local prepare_calls,inject_busy=0,false
  local inside_candidate_guard=false
  store.prepare=function(target,id,pattern,policy,pb,guard,...)
    prepare_calls=prepare_calls+1
    local candidate,reason=original_prepare(target,id,pattern,policy,pb,function(...)
      inside_candidate_guard=true
      local results={guard(...) }
      inside_candidate_guard=false
      return unpack(results)
    end,...)
    return candidate,reason
  end
  store.allocate=function(target,...)
    local id,reason=original_allocate(target,...)
    if inside_candidate_guard and not inject_busy then
      inject_busy=true
      writer.status='busy';writer.token={}
    end
    return id,reason
  end
  local cancels=writer.cancels
  local changed=ctx:make_independent()
  assert(not changed,'writer occupancy drift during the candidate guard was accepted')
  assert(inject_busy,'candidate guard did not reach its final allocation inspection')
  assert(prepare_calls==1,'writer drift caused an implicit identity retry')
  assert(writer.status=='busy' and writer.cancels==cancels,
    'candidate guard canceled or released the newly busy writer')
  assert(song.tool_data==original_raw and source_write_attempts==0,
    'candidate guard attempted or changed the source store after writer drift')
  assert(selected.name==original_name and name_write_attempts==0,
    'candidate guard attempted or changed phrase ownership after writer drift')

  writer.status='idle';writer.token=nil
  setmetatable(song,old_song_meta)
  rawset(song,'tool_data',source_bytes)
  setmetatable(selected,old_phrase_meta)
  rawset(selected,'name',name)
  local retried,retry_result=ctx:make_independent()
  store.prepare,store.allocate=original_prepare,original_allocate
  assert(retried,retry_result)
  assert(prepare_calls==2,'explicit idle retry did not start exactly one new transaction')
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
  local ctx,song,instrument,selected,_,source,holders=setup(1)
  local outgoing=seq.copy_source(source)
  outgoing.pitch_events[1]=seq.new_pitch(11,0,false,false)
  assert(ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true}))
  assert(ctx:transition('edit',{source=outgoing,output_policy='repeat',pb_range=12}))
  assert(cache.put(song,instrument,selected,outgoing,'repeat',12,ctx:draft_options()))
  local _,draft_policy,draft_pb,draft_before=cache.get(song,instrument,selected,ctx:draft_options())
  assert(draft_before and draft_before.token and draft_before.revision)
  local other_holder=helper.phrase(source,101)
  song.instruments[#song.instruments+1]=helper.instrument({other_holder})
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
  song.instruments[#song.instruments]=nil
  assert(ctx:transition('refresh'))
  local state=ctx:editor_state()
  local _,after_policy,after_pb,draft_after=cache.get(song,instrument,selected)
  assert(seq.same_source(state.source,outgoing) and state.output_policy=='repeat' and state.pb_range==12,
    'transaction rollback changed the selected dirty source or settings')
  assert(after_policy==draft_policy and after_pb==draft_pb and draft_after.token==draft_before.token and
      draft_after.revision==draft_before.revision and draft_after.recovered==draft_before.recovered and
      draft_after.persistent==draft_before.persistent and
      draft_after.recovery_token==draft_before.recovery_token and
      draft_after.recovery_revision==draft_before.recovery_revision,
    'transaction rollback changed the exact selected draft revision')
  assert(ownership.id(other_holder)==101 and not ctx:integrity_state().blocked)
end

-- A matching object-local editor draft follows the selected object only after
-- the new committed baseline is verified; an ambiguous old-ID durable draft stays.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local old_draft=seq.new_pattern(6)
  assert(store.write_draft(song,instrument,selected,old_draft,'play_once',0))
  local other_holder=helper.phrase(source,101)
  song.instruments[#song.instruments+1]=helper.instrument({other_holder})
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

-- A failing name getter leaves the transaction uncertain without guessing the
-- value to restore; the mutation snapshot keeps Revalidate read-only.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local original_name=selected.name
  local original_meta=getmetatable(selected)
  local backing=original_name
  local written_name
  rawset(selected,'name',nil)
  setmetatable(selected,{__eq=original_meta.__eq,
    __index=function(object,key)
      if key=='name' then
        if written_name and backing==written_name then error('injected name getter failure',0) end
        return backing
      end
      return original_meta.__index and original_meta.__index(object,key) or nil
    end,
    __newindex=function(object,key,value)
      if key=='name' then
        backing=value
        if value~=original_name then written_name=value end
      else rawset(object,key,value) end
    end})
  local original_read=store.read_entry
  store.read_entry=function(target,id,...)
    if id==103 then return nil,'injected post-name verification failure' end
    return original_read(target,id,...)
  end
  local changed=ctx:make_independent()
  store.read_entry=original_read
  setmetatable(selected,original_meta)
  assert(not changed,'unreadable ownership name was reported as a safe rollback')
  assert(backing==written_name and ownership.id({name=backing})==103,
    'rollback guessed at a name whose current value could not be read')
  assert(ownership.id(holders[2])==101 and ctx:integrity_state().blocked,
    'unreadable rollback state did not preserve the blocker')
end

-- Store rollback refuses to overwrite song data changed reentrantly by the
-- name setter and retains the exact newer value as recovery evidence.
do
  local ctx,song,_,selected,_,_,holders=setup(2)
  local original_name=selected.name
  local original_meta=getmetatable(selected)
  local backing=original_name
  local external_data
  rawset(selected,'name',nil)
  setmetatable(selected,{__eq=original_meta.__eq,
    __index=function(object,key)
      if key=='name' then return backing end
      return original_meta.__index and original_meta.__index(object,key) or nil
    end,
    __newindex=function(object,key,value)
      if key=='name' then
        backing=value
        if value~=original_name then
          song.tool_data=song.tool_data..'external-change'
          external_data=song.tool_data
          error('injected name write failure after external store change',0)
        end
      else rawset(object,key,value) end
    end})
  local changed=ctx:make_independent()
  setmetatable(selected,original_meta)
  assert(not changed,'external store change was accepted')
  assert(song.tool_data==external_data,'rollback overwrote an intervening song data change')
  assert(backing==original_name and ownership.id(holders[2])==101,
    'selected ownership name or collision holder was not preserved')
  assert(ctx:integrity_state().blocked,'uncertain store rollback did not block the song')
end

-- Verified identity commit remains a committed outcome when inventory adoption
-- rejects or throws; the blocker prevents stale UI state from authorizing writes.
for _,fault in ipairs({'false','throw'}) do
  local inventory_module=require('runtime.inventory')
  local original_new=inventory_module.new
  inventory_module.new=function(...)
    local inventory=original_new(...)
    inventory.adopt=function()
      if fault=='throw' then error('injected adoption exception',0) end
      return false,'injected adoption rejection'
    end
    return inventory
  end
  local ctx,song,instrument,selected,_,source,holders,_,log=setup(1)
  local outgoing=seq.copy_source(source)
  outgoing.pitch_events[1]=seq.new_pitch(10,0,false,false)
  assert(ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true}))
  assert(ctx:transition('edit',{source=outgoing,output_policy='repeat',pb_range=2}))
  assert(cache.put(song,instrument,selected,outgoing,'repeat',2,ctx:draft_options()))
  local _,draft_policy,draft_pb,draft_before=cache.get(song,instrument,selected,ctx:draft_options())
  local other_holder=helper.phrase(source,101)
  song.instruments[#song.instruments+1]=helper.instrument({other_holder})
  inventory_module.new=original_new
  local changed,result=ctx:make_independent()
  assert(changed and result.committed==true and type(result.warning)=='string',
    fault..' post-commit adoption was reported as mutation-free rejection')
  assert(ownership.id(selected)==result.id and ownership.id(other_holder)==101,
    fault..' adoption failure lost the committed identity result')
  assert(ctx:integrity_state().blocked,'adoption failure did not block the live song')
  assert(not ctx:request_generation('manual'),'adoption failure left stale editor state writable')
  assert(log.sinks==0,'adoption failure entered the musical scheduler')
  local state=ctx:editor_state()
  local draft_matches,draft_after=cache.matches_values(song,instrument,selected,outgoing,'repeat',2)
  assert(seq.same_source(state.source,outgoing) and state.output_policy=='repeat' and state.pb_range==2,
    fault..' adoption failure lost the dirty source or settings')
  assert(draft_matches and draft_policy=='repeat' and draft_pb==2 and draft_after.token==draft_before.token and
      draft_after.revision==draft_before.revision and draft_after.recovered==draft_before.recovered and
      draft_after.persistent==draft_before.persistent and
      draft_after.recovery_token==draft_before.recovery_token and
      draft_after.recovery_revision==draft_before.recovery_revision,
    fault..' adoption failure changed the exact selected draft revision')
end

-- A committed adoption blocker can clear only after its retained evidence
-- verifies, including after the same document is detached and reattached.
do
  local inventory_module=require('runtime.inventory')
  local original_new=inventory_module.new
  inventory_module.new=function(...)
    local inventory=original_new(...)
    inventory.adopt=function() return false,'injected adoption rejection' end
    return inventory
  end
  local ctx,song,instrument,selected,_,source=setup(1)
  inventory_module.new=original_new
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})

  local changed,result=ctx:make_independent()
  assert(changed and result.committed==true,'adoption failure lost the committed outcome')
  song.selected_instrument,song.selected_phrase=instrument,selected
  local status,proof=ctx:revalidation_status()
  assert(status.verified and proof,'stable committed evidence did not produce a revalidation proof: '..
    tostring(status.reason))
  assert(ctx:revalidate(proof),'stable committed evidence could not clear its blocker')
  assert(not ctx:integrity_state().blocked,'revalidation left the committed blocker active')
  assert(ownership.id(selected)==result.id,'revalidation changed committed identity')

  local inventory_module_new=inventory_module.new
  inventory_module.new=function(...)
    local inventory=inventory_module_new(...)
    inventory.adopt=function() return false,'injected adoption rejection' end
    return inventory
  end
  local attached_ctx,attached_song,attached_instrument,attached_phrase,_,attached_source=setup(1)
  inventory_module.new=inventory_module_new
  attached_song.instruments[#attached_song.instruments+1]=helper.instrument({
    helper.phrase(attached_source,INDEPENDENCE_COLLISION_ID)})
  local attached,attached_result=attached_ctx:make_independent()
  assert(attached and attached_result.committed==true,'reattach case lost the committed outcome')
  attached_song.selected_instrument,attached_song.selected_phrase=attached_instrument,attached_phrase
  attached_ctx:release_document()
  attached_ctx:attach_document(attached_song)
  attached_ctx:open_dialog()
  local resumed_status,resumed_proof=attached_ctx:revalidation_status()
  assert(resumed_status.verified and resumed_proof,
    'same-song reattach did not resume committed recovery verification')
  assert(attached_ctx:revalidate(resumed_proof),
    'same-song reattach could not clear verified committed recovery')
  assert(not attached_ctx:integrity_state().blocked and ownership.id(attached_phrase)==attached_result.id,
    'same-song revalidation left the blocker or changed committed identity')
end

-- A post-commit callback cannot make intervening protected phrase edits part
-- of the recovery baseline.
do
  local inventory_module=require('runtime.inventory')
  local original_new=inventory_module.new
  local protected_phrase
  inventory_module.new=function(...)
    local inventory=original_new(...)
    inventory.adopt=function()
      protected_phrase.name='Externally changed protected phrase'
      return false,'injected adoption rejection'
    end
    return inventory
  end
  local ctx,song,_,selected,other_phrase,source=setup(1)
  protected_phrase=other_phrase
  inventory_module.new=original_new
  song.instruments[#song.instruments+1]=helper.instrument({
    helper.phrase(source,INDEPENDENCE_COLLISION_ID)})
  local changed,result=ctx:make_independent()
  assert(changed and result.committed==true,'protected-state test lost committed identity')
  assert(other_phrase.name=='Externally changed protected phrase',
    'injected protected-state change did not occur')
  local status=ctx:revalidation_status()
  assert(not status.verified and not ctx:revalidate(),
    'intervening protected phrase edit was accepted as the recovery baseline')
  assert(ownership.id(selected)==result.id,
    'protected-state recovery check changed the committed identity')
end

-- Recovery capture and recording failures preserve the committed identity and
-- keep generation and revalidation blocked after the dialog is reopened.
for _,fault in ipairs({'capture_throw','record_false','record_throw'}) do
  local inventory_module=require('runtime.inventory')
  local original_inventory_new=inventory_module.new
  inventory_module.new=function(...)
    local inventory=original_inventory_new(...)
    inventory.adopt=function() return false,'injected adoption rejection' end
    return inventory
  end
  local integrity_module=require('runtime.integrity')
  local original_integrity_new=integrity_module.new
  integrity_module.new=function(...)
    local integrity=original_integrity_new(...)
    if fault=='capture_throw' then
      integrity.capture_committed=function()
        error('injected committed recovery capture exception',0)
      end
    elseif fault=='record_false' then
      integrity.record=function() return false,'injected recovery recording rejection' end
    else
      integrity.record=function() error('injected recovery recording exception',0) end
    end
    return integrity
  end
  local ctx,song,_,selected,_,source=setup(1)
  inventory_module.new=original_inventory_new
  integrity_module.new=original_integrity_new
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})

  local changed,result=ctx:make_independent()
  assert(changed and result.committed==true and type(result.warning)=='string',
    fault..' recovery failure hid the committed outcome')
  assert(ownership.id(selected)==result.id and
      seq.same_source(assert(store.read_entry(song,result.id)),source),
    fault..' recovery failure lost the committed identity or source')
  assert(ctx:integrity_state().blocked and not ctx:musical_eligibility(),
    fault..' recovery failure left stale runtime state writable')
  local status=ctx:revalidation_status()
  assert(status.verified==false,fault..' recovery failure reported verified state')
  assert(not ctx:request_generation('manual'),fault..' recovery failure allowed generation')
  assert(not ctx:revalidate(),fault..' recovery failure allowed revalidation')

  ctx:close_dialog()
  ctx:open_dialog()
  assert(ctx:integrity_state().blocked and not ctx:request_generation('manual') and
      not ctx:revalidate(),
    fault..' recovery blocker did not survive dialog reopen')
  assert(ownership.id(selected)==result.id and
      seq.same_source(assert(store.read_entry(song,result.id)),source),
    fault..' dialog reopen hid the committed result')
end

-- A failed editor rebind keeps the selected dirty source available and blocks
-- writes until the committed identity can be reconciled.
for _,fault in ipairs({'false','throw'}) do
  local ctx,song,instrument,selected,_,source=setup(1)
  local outgoing=seq.copy_source(source)
  outgoing.pitch_events[1]=seq.new_pitch(9,0,false,false)
  assert(ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true}))
  assert(ctx:transition('edit',{source=outgoing,output_policy='repeat',pb_range=24}))
  assert(cache.put(song,instrument,selected,outgoing,'repeat',24,ctx:draft_options()))
  local _,draft_policy,draft_pb,draft_before=cache.get(song,instrument,selected,ctx:draft_options())
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local transition=ctx.transition
  ctx.transition=function(self,kind,values)
    if kind=='programmatic' and values and values.restore==true then
      if fault=='throw' then error('injected editor restoration exception',0) end
      return nil,'injected editor restoration rejection'
    end
    return transition(self,kind,values)
  end
  local changed,result=ctx:make_independent()
  ctx.transition=transition
  assert(changed and result.committed==true and result.warning,
    'editor restoration failure was reported as mutation-free rejection')
  assert(seq.same_source(ctx:editor_state().source,outgoing),
    'editor restoration failure lost the selected dirty source')
  local state=ctx:editor_state()
  local _,after_policy,after_pb,draft_after=cache.get(song,instrument,selected,ctx:draft_options())
  assert(state.output_policy=='repeat' and state.pb_range==24 and after_policy==draft_policy and
      after_pb==draft_pb and draft_after.token==draft_before.token and
      draft_after.revision==draft_before.revision and draft_after.recovered==draft_before.recovered and
      draft_after.persistent==draft_before.persistent and
      draft_after.recovery_token==draft_before.recovery_token and
      draft_after.recovery_revision==draft_before.recovery_revision,
    fault..' editor restoration failure changed the dirty settings or exact draft revision')
  assert(ctx:integrity_state().blocked and not ctx:musical_eligibility(),
    'editor restoration failure left stale UI state writable')
  assert(ownership.id(selected)==result.id)
end

-- Reconciliation must validate the classified target, not only a truthy return.
for _,fault in ipairs({'false','throw','unavailable'}) do
  local ctx,song,_,selected,_,source=setup(1)
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local transition=ctx.transition
  ctx.transition=function(self,kind,values)
    if kind=='refresh' then
      if fault=='throw' then error('injected reconciliation exception',0) end
      if fault=='unavailable' then
        return {kind='unavailable',reason='injected unavailable selected phrase',
          phrase=nil}
      end
      return nil,'injected reconciliation rejection'
    end
    return transition(self,kind,values)
  end
  local changed,result=ctx:make_independent()
  ctx.transition=transition
  assert(changed and result.committed==true and result.warning,
    'reconciliation failure was reported as a mutation-free rejection')
  assert(ownership.id(selected)==result.id and ctx:integrity_state().blocked,
    'reconciliation failure lost or exposed the committed identity')
  assert(not ctx:request_generation('manual'),'reconciliation failure left stale UI state writable')
end

-- A target switch during post-commit reconciliation must not bind the committed
-- source to the newly selected phrase.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local other_source=seq.new_pattern(5)
  other_source.pitch_events[1]=seq.new_pitch(11,0,false,false)
  local other_phrase=helper.phrase(other_source,207)
  instrument.phrases[#instrument.phrases+1]=other_phrase
  assert(store.save(song,207,other_source,'play_once',0))
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local transition=ctx.transition
  ctx.transition=function(self,kind,values)
    if kind=='refresh' then
      local rebound,rebind_error=self:restore_editor_target(instrument,other_phrase)
      assert(rebound,rebind_error)
    end
    return transition(self,kind,values)
  end
  local changed,result=ctx:make_independent()
  ctx.transition=transition
  local state=ctx:editor_state()
  assert(changed and result.committed==true and result.warning,
    'post-commit target switch was not reported as blocked commit')
  assert(ownership.id(selected)==result.id and ctx:target_state().phrase==other_phrase,
    'post-commit target switch lost the committed phrase or selected target')
  assert(seq.same_source(state.source,other_source) and state.output_policy=='play_once' and state.pb_range==0,
    'post-commit source restoration replaced the newly selected phrase editor')
  assert(ctx:integrity_state().blocked and not ctx:request_generation('manual'),
    'post-commit target switch left stale runtime state writable')
end

-- A dialog session change after commit blocks editor restoration for the old
-- operation even when the song and selected phrase remain the same.
do
  local ctx,song,_,selected,_,source=setup(1)
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local original_session=ctx:lifetime_state().session
  local transition=ctx.transition
  ctx.transition=function(self,kind,values)
    if kind=='refresh' then self:open_dialog() end
    return transition(self,kind,values)
  end
  local changed,result=ctx:make_independent()
  ctx.transition=transition
  assert(changed and result.committed==true and result.warning,
    'post-commit session change was reported as a completed adoption')
  assert(ctx:lifetime_state().session>original_session and ownership.id(selected)==result.id,
    'post-commit session change lost the committed identity or new session')
  assert(ctx:integrity_state().blocked and not ctx:request_generation('manual'),
    'post-commit session change left stale runtime state writable')
end

-- Draft persistence rejection and exception keep the object-local editor copy
-- and surface a recoverable warning after the committed rebind.
for _,fault in ipairs({'false','throw'}) do
  local ctx,song,instrument,selected,_,source=setup(1)
  local outgoing=seq.copy_source(source)
  outgoing.pitch_events[1]=seq.new_pitch(10,0,false,false)
  assert(ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true}))
  assert(ctx:transition('edit',{source=outgoing,output_policy='play_once',pb_range=0}))
  assert(cache.put(song,instrument,selected,outgoing,'play_once',0,ctx:draft_options()))
  song.instruments[#song.instruments+1]=helper.instrument({helper.phrase(source,101)})
  local original_write=store.write_draft
  local calls=0
  store.write_draft=function(...)
    calls=calls+1
    if fault=='throw' then error('injected draft rebind exception',0) end
    return nil,'injected draft rebind rejection'
  end
  local changed,result=ctx:make_independent()
  store.write_draft=original_write
  local state=ctx:editor_state()
  assert(changed and ownership.id(selected)==result.id,
    fault..' draft persistence failure lost committed identity')
  assert(calls==1 and seq.same_source(state.source,outgoing) and state.draft_warning,
    fault..' draft persistence failure lost the selected dirty source or warning')
  assert(not ctx:integrity_state().blocked,
    fault..' recoverable object-local draft unnecessarily blocked the song')
end

-- Failed pre-commit resolution preserves the durable dirty draft value and its
-- exact revision, including the old-ID recovery association.
do
  local ctx,song,instrument,selected,_,source=setup(1)
  local outgoing=seq.copy_source(source)
  outgoing.pitch_events[1]=seq.new_pitch(12,0,false,false)
  assert(ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true}))
  assert(ctx:transition('edit',{source=outgoing,output_policy='play_once',pb_range=0}))
  assert(cache.put(song,instrument,selected,outgoing,'play_once',0,ctx:draft_options()))
  local _,_,_,before_metadata=cache.get(song,instrument,selected,ctx:draft_options())
  local draft_bytes=song.tool_data
  local other=helper.phrase(source,101)
  song.instruments[#song.instruments+1]=helper.instrument({other})
  local original=store.prepare
  store.prepare=function() return nil,'injected candidate preparation rejection' end
  local changed=ctx:make_independent()
  store.prepare=original
  assert(not changed and ownership.id(selected)==101,
    'candidate preparation failure changed selected identity')
  assert(song.tool_data==draft_bytes,'candidate failure changed ambiguous old-ID draft bytes')
  assert(before_metadata and before_metadata.revision and before_metadata.persistent,
    'candidate setup did not persist a revisioned selected draft')
  assert(seq.same_source(ctx:editor_state().source,outgoing),
    'candidate failure lost the selected object-local dirty source')
end

print('ACID runtime Make Independent transaction passed')
