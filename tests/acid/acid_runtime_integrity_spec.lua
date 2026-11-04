local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')

local function fixture()
 local song,instrument,phrase,other=helper.fixture()
 local log={captures=0,sinks=0}
 local writer={state=function()return 'idle',nil end}
 local ctx=context.new({writer=writer,capture=function(_,token)
  log.captures=log.captures+1
  log.token=token
  return {token=token}
 end,sink=function(_,done)
  log.sinks=log.sinks+1
  log.done=done
  return true
 end})
 ctx:attach_document(song);ctx:open_dialog()
 local target=ctx:bind_phrase(instrument,phrase)
 assert(target.kind=='owned' and target.baseline)
 assert(ctx:request_generation('manual'))
 return ctx,log,song,instrument,phrase,other,target.baseline
end

local function blocker(instrument,phrase,baseline)
 return {reason='ACID cannot safely update this song',instrument=instrument,
  phrase=phrase,baseline=baseline,recovery={}}
end

-- Recorded song blockers survive navigation, dialog reopen, and same-song reattachment.
do
 local ctx,log,song,instrument,phrase,other,baseline=fixture()
 local token=log.token
 assert(token and ctx:record_blocker(token,blocker(instrument,phrase,baseline)))
 log.done({kind='failed'})
 local original=assert(ownership.snapshot(phrase))
 local raw=song.tool_data

 ctx:close_dialog();ctx:open_dialog()
 assert(ctx:bind_new(instrument).kind=='new')
 assert(ctx:bind_phrase(instrument,other).kind=='owned')
 for _,trigger in ipairs({'manual','live'}) do
  assert(not ctx:request_generation(trigger),trigger..' request escaped the song blocker')
 end
 assert(not ctx:request_duplicate(),'Duplicate escaped the song blocker')
 assert(log.captures==1 and log.sinks==1,'blocked actions crossed capture or dispatch')

 assert(ctx:release_document())
 ctx:attach_document(song);ctx:open_dialog()
 assert(ctx:integrity_state().blocked,'same-song reattachment discarded recorded evidence')
 assert(not ctx:request_generation('manual'),'same-song reattachment admitted Generate')
 assert(log.captures==1 and log.sinks==1)
 assert(song.tool_data==raw and ownership.compare(original,assert(ownership.snapshot(phrase))),
  'blocked requests changed persisted source or native phrase state')
end

-- Metadata uncertainty records a song blocker that survives integrity-owner suspension.
do
 local integrity=require('runtime.integrity')
 local song=select(1,helper.fixture())
 local owner=integrity.new(song,nil)
 local raw=song.tool_data
 local receipt=assert(owner:capture_metadata(raw))
 song.tool_data=(raw or '')..'changed'
 assert(owner:record(receipt))
 assert(owner:state().blocked and owner:state().reason=='ACID cannot safely update this song')
 owner:suspend()
 assert(owner:resume(song,nil))
 assert(owner:state().blocked,'same-song integrity resume discarded metadata evidence')
 assert(song.tool_data~=(raw or ''),'fixture did not retain the uncertain metadata outcome')
end

print('ACID runtime integrity blockers remain fail-closed')
