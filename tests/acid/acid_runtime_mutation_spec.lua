dofile('tests/bootstrap.lua')('acid')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')
local validator=require('writers.phrase_validator')
local phrase_fixture=dofile('tests/acid/complete_phrase_fixture.lua')
local function fixture()
 local source=phrase_fixture();source.name=assert(ownership.make_name(source,1))
 local instrument={name='Sampler',phrases={source}}
 local song={instruments={instrument},selected_instrument=instrument,selected_phrase=source,
  tool_data='',is_undo_redoing=function()return false end}
 local temporaries={}
 local writer={status='idle'}
 function writer:state()return self.status,self.token end
 function writer.is_temporary(_,_,phrase)return temporaries[phrase]==true end
 local log={captures=0,sinks=0,cancels=0}
 local ctx=context.new{writer=writer,capture=function(_,token)
  log.captures=log.captures+1;log.token=token;return {token=token}
 end,sink=function(_,done)log.sinks=log.sinks+1;log.done=done;return true end,
 cancel=function()log.cancels=log.cancels+1;return true end}
 ctx:attach_document(song);ctx:open_dialog();assert(ctx:bind_new(instrument).kind=='new')
 assert(ctx:request_generation('manual'))
 return ctx,log,song,instrument,source,temporaries,writer
end

-- Missing registries reject before invoking the mutation action.
do
 local ctx,log,_,_,_,_,writer=fixture()
 writer.is_temporary=nil
 local ran=false
 assert(not pcall(function()ctx:mutate(log.token,function()ran=true end)end))
 assert(not ran and not ctx:mutation_state().failed)
end

-- Unregistered copied owners and unreadable registry responses fail closed.
for _,registry in ipairs({'copy','invalid','throws','removed'})do
 local ctx,log,_,instrument,source,_,writer=fixture()
 local ok=pcall(function()ctx:mutate(log.token,function()
  if registry=='copy' then instrument.phrases[2]={name=source.name}
  elseif registry=='invalid' then writer.is_temporary=function()return nil end
  elseif registry=='throws' then writer.is_temporary=function()error('registry unavailable')end
  else writer.is_temporary=nil end
 end)end)
 assert(not ok and ctx:mutation_state().failed and not log.token:is_current())
 assert(ctx:integrity_state().blocked)
end

-- Failed scopes require exact native restoration and explicit proof after settlement.
do
 local ctx,log,song,instrument,source=fixture()
 local name,base_note,store=source.name,source.base_note,song.tool_data
 local sentinel={reason='mutation failure'}
 local ok,reason=pcall(function()ctx:mutate(log.token,function()
  source.name='Changed';source.base_note=source.base_note+1
  song.tool_data='changed';instrument.phrases[2]={name='Recovery'}
  error(sentinel)
 end)end)
 assert(not ok and rawequal(reason,sentinel) and ctx:integrity_state().blocked)
 assert(not ctx:revalidation_status().verified)
 log.done({kind='failed'})
 assert(not ctx:revalidation_status().verified)
 instrument.phrases[2]=nil;source.name=name;source.base_note=base_note
 assert(not ctx:revalidation_status().verified,'changed store was accepted')
 song.tool_data=store
 local status,proof=ctx:revalidation_status()
 assert(status.verified and proof and ctx:mutation_state().failed)
 source.name='Changed again'
 assert(not ctx:revalidate(proof),'restoration proof accepted changed phrase')
 source.name=name
 local restored,current=ctx:revalidation_status()
 assert(restored.verified and ctx:revalidate(current))
 assert(not ctx:mutation_state().failed and not ctx:integrity_state().blocked)
 assert(log.captures==1 and log.sinks==1,'recovery retried generation')
 assert(ctx:reconcile().kind=='new')
end

-- Copy/name/list callbacks remain synchronous dirtiness; only neutral outer exit reconciles.
do
 local ctx,log,song,instrument,source,temporaries=fixture()
 local classified=0
 local classify=validator.classify
 validator.classify=function(...)classified=classified+1;return classify(...)end
 local first,second,third=ctx:mutate(log.token,function()
  local backup={name=source.name}
  instrument.phrases[2]=backup;temporaries[backup]=true
  ctx:mark_dirty('phrase inserted')
  assert(ctx:mutation_state().depth==1)
  assert(ctx:target_state().kind=='unavailable')
  assert(not ctx:phrase_choices(instrument))
  assert(not ctx:draft_options().validate(song,instrument,source))
  local reconciled=ctx:reconcile()
  assert(not reconciled or reconciled.kind=='unavailable')
  assert(classified==0,'classification ran during unfinished copy')
  ctx:mutate(log.token,function()
   assert(ctx:mutation_state().depth==2)
   local ran=false
   pcall(function()ctx:mutate({},function()ran=true end)end)
   assert(not ran,'foreign nested token executed')
   backup.name='ACID backup';ctx:mark_dirty('neutral name')
  end)
  assert(ctx:mutation_state().depth==1)
  song.selected_phrase=backup
  return 'value',nil,3
 end)
 validator.classify=classify
 assert(first=='value' and second==nil and third==3,'scope lost return values')
 local state=ctx:mutation_state()
 assert(state.depth==0 and state.pending and state.dirty and not state.failed)
 state.depth=20;state.failed=true
 assert(ctx:mutation_state().depth==0 and not ctx:mutation_state().failed)
 assert(log.token:is_current(),'internal notifications revoked the request')
 assert(ctx:reconcile().kind=='new','internal native temporary must not replace explicit New')
 assert(not ctx:mutation_state().pending)
 ctx:reconcile()
 assert(log.captures==1 and log.sinks==1)
 ctx:mark_dirty('delayed native callback')
 assert(not log.token:is_current(),'out-of-scope notification was treated as internal')
 assert(log.captures==1 and log.sinks==1)
end

-- Unneutralized temporary ownership cannot leave a successful mutation scope.
do
 local ctx,log,song,instrument,source,temporaries=fixture()
 local ok=pcall(function()ctx:mutate(log.token,function()
  local backup={name=source.name};instrument.phrases[2]=backup;temporaries[backup]=true
  ctx:mark_dirty('copy')
 end)end)
 assert(not ok and ctx:mutation_state().failed)
 assert(ctx:mutation_state().depth==0 and not log.token:is_current())
 assert(ctx:target_state().kind=='unavailable')
 assert(not ctx:draft_options().validate(song,instrument,source))
 assert(log.captures==1 and log.sinks==1)
 local reconciled=ctx:reconcile()
 assert(not reconciled or reconciled.kind=='unavailable','failed scope reconciled unfinished copy')
end

-- Nested errors unwind depth and revoke; stale/foreign tokens never execute an action.
do
 local ctx,log=fixture()
 local ran=false
 local ok=pcall(function()ctx:mutate({},function()ran=true end)end)
 assert(not ran)
 local sentinel={reason='nested failure'}
 local result,failure=pcall(function()ctx:mutate(log.token,function()
  ctx:mutate(log.token,function()error(sentinel)end)
 end)end)
 assert(not result and rawequal(failure,sentinel) and ctx:mutation_state().depth==0)
 assert(not log.token:is_current())
 pcall(function()ctx:mutate(log.token,function()ran=true end)end)
 assert(not ran)
 assert(log.captures==1 and log.sinks==1)
end
do
 local ctx,log=fixture()
 pcall(function()ctx:mutate(log.token,function()ctx:release_document()end)end)
 assert(ctx:mutation_state().depth==0,'release during scope corrupted nesting depth')
 assert(not log.token:is_current())
end
print('ACID synchronous runtime mutation and reconciliation passed')
