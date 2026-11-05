local helper=dofile("tests/acid/runtime_phrase_fixture.lua")
local context=require("runtime.context")
local seq=require("model.sequencer")
local store=require("renoise.pattern_store")
local cache=require("runtime.draft_cache")
local ownership=require("renoise.phrase_ownership")
local ORIGIN_ID=101
local COPY_ID=103

local function fixture(dirty,label)
  local song,instrument,phrase,other,source=helper.fixture()
  if label then
    local candidate=assert(store.prepare(song,ORIGIN_ID,source,"play_once",0,function()return true end,
      nil,label,true))
    assert(store.commit(song,candidate))
  end
  local log={count=0}
  local writer={state=function()return "idle",nil end,is_temporary=function()return false end}
  local ctx=context.new{writer=writer,capture=function()error("runtime owns capture")end,
    sink=function(request,done)log.count=log.count+1;log.request=request;log.done=done;return true end}
  ctx:attach_document(song);ctx:open_dialog()
  assert(ctx:restore_editor_target(instrument,phrase))
  local edited=assert(seq.copy_source(source))
  if dirty then
    edited.pitch_events[32]=seq.new_pitch(7,1,true,true)
    assert(ctx:transition("edit",{source=edited,output_policy="play_once",pb_range=0,
      label=label or "Pattern 101",label_custom=label~=nil}))
  end
  return ctx,log,song,instrument,phrase,other,source,edited
end

do
  local ctx,log,song,instrument,phrase,_,source,edited=fixture(true,"Acid.- ")
  local matches,before=cache.matches_values(song,instrument,phrase,edited,"play_once",0,"Acid.- ",true)
  assert(matches)
  local raw=song.tool_data
  assert(ctx:request_duplicate())
  local request=log.request
  assert(log.count==1 and request.kind=="create" and request.operation=="duplicate")
  assert(request.target_kind=="new" and request.phrase==nil and request.id==nil and request.baseline==nil)
  assert(rawequal(request.instrument,instrument) and request.draft_capture==nil)
  assert(ctx:target_state().kind=="owned" and rawequal(ctx:target_state().phrase,phrase))
  assert(seq.same_source(request.source,source) and not seq.same_source(request.source,edited))
  assert(request.label=="Acid copy" and request.label_custom==true)
  assert(request.origin.baseline.id==ORIGIN_ID and request.origin.raw==raw)
  assert(request:validate_checkpoint() and request:validate_origin_checkpoint())
  local _,after=cache.matches_values(song,instrument,phrase,edited,"play_once",0,"Acid.- ",true)
  assert(before.token==after.token and before.revision==after.revision and song.tool_data==raw)
  log.done({kind="failure",status="failed",token=request.token,epoch=request.epoch,
    request=request,reason="injected failure"})
  assert(seq.same_source(ctx:editor_state().source,edited) and song.tool_data==raw)
  local _,retained=cache.matches_values(song,instrument,phrase,edited,"play_once",0,"Acid.- ",true)
  assert(retained.token==before.token and retained.revision==before.revision)
  ctx:release_document()
end

for _,case in ipairs({{"Acid Pattern","Acid Pattern copy"},
    {string.rep("A",26)..".B",string.rep("A",26).." copy"}}) do
  local ctx,log=fixture(false,case[1])
  local original=cache.put
  cache.put=function()error("clean duplicate saved a draft")end
  local ok,accepted=pcall(ctx.request_duplicate,ctx)
  cache.put=original
  assert(ok and accepted and log.request.label==case[2])
  ctx:release_document()
end

for _,fault in ipairs({"save","readback","token"}) do
  local ctx,log,song,instrument,phrase,_,_,edited=fixture(true)
  local raw=song.tool_data
  local revision=ctx:revision_state()
  local _,before=cache.matches_values(song,instrument,phrase,edited,"play_once",0)
  local original_put,original_read,original_matches=cache.put,store.read_draft,cache.matches_values
  if fault=="save" then cache.put=function()return nil,"injected save failure" end
  elseif fault=="readback" then store.read_draft=function()return nil,"injected readback failure" end
  else
    local calls=0
    cache.matches_values=function(...)
      local matches,metadata=original_matches(...)
      calls=calls+1
      if calls>1 and metadata then metadata.revision=metadata.revision+1 end
      return matches,metadata
    end
  end
  local ok,accepted=pcall(ctx.request_duplicate,ctx)
  cache.put,store.read_draft,cache.matches_values=original_put,original_read,original_matches
  assert(ok and not accepted and log.count==0,"failed prerequisite admitted duplicate: "..fault)
  assert(song.tool_data==raw and seq.same_source(ctx:editor_state().source,edited))
  assert(ctx:revision_state().operation_serial==revision.operation_serial)
  local _,after=cache.matches_values(song,instrument,phrase,edited,"play_once",0)
  assert(before.token==after.token and before.revision==after.revision)
  ctx:release_document()
end

local mutations={
  seal=function(ctx,log,song,instrument,phrase)phrase.name=phrase.name.." changed" end,
  source=function(ctx,log,song)
    assert(store.save(song,ORIGIN_ID,seq.new_pattern(5),"play_once",0))
  end,
  label=function(ctx,log,song,instrument,phrase,source)
    local candidate=assert(store.prepare(song,ORIGIN_ID,source,"play_once",0,function()return true end,
      nil,"Changed",true));assert(store.commit(song,candidate))
  end,
  phrase=function(ctx,log,song,instrument,phrase,source)instrument.phrases[1]=helper.phrase(source,ORIGIN_ID)end,
  duplicate_id=function(ctx,log,song,instrument,phrase,source)
    song.instruments[2]=helper.instrument({helper.phrase(source,ORIGIN_ID)})
  end,
  output=function(ctx,log,song,instrument,phrase)phrase.lines[1].note_columns[1].note_value=80 end,
  request_source=function(ctx,log)log.request.source.pitch_events[32].accent=true end,
  request_origin=function(ctx,log)log.request.origin.label="Changed" end,
  callback=function(ctx,log)log.request.validate_origin_checkpoint=function()return true end end,
  binding=function(ctx,log,song,instrument)ctx:bind_new(instrument)end,
}
for name,mutate in pairs(mutations) do
  local ctx,log,song,instrument,phrase,_,source=fixture(false,"Acid Pattern")
  assert(ctx:request_duplicate())
  mutate(ctx,log,song,instrument,phrase,source)
  assert(not log.request:validate_checkpoint(),"changed duplicate origin accepted: "..name)
  ctx:release_document()
end

do
  local ctx,log,song,instrument,phrase,_,source=fixture(true,"Acid Pattern")
  assert(ctx:request_duplicate())
  local request=log.request
  local candidate=assert(store.prepare(song,COPY_ID,request.source,request.output_policy,request.pb_range,
    function()return request:is_current()end,nil,request.label,request.label_custom))
  instrument.phrases[#instrument.phrases+1]=helper.phrase(source,COPY_ID)
  assert(request:validate_origin_checkpoint())
  assert(store.commit(song,candidate))
  assert(request:validate_origin_checkpoint(candidate),"verified candidate rejected")
  assert(not request:validate_origin_checkpoint({}),"forged candidate accepted")
  ctx:release_document()
end

do
  local ctx,log,_,instrument=fixture(false)
  ctx:bind_new(instrument)
  assert(not ctx:request_duplicate() and log.count==0)
  assert(not ctx:request_generation("manual","forged"))
  ctx:release_document()
end
do
  local ctx,log=fixture(false)
  local capacity=renoise.Instrument.MAX_NUMBER_OF_PHRASES
  renoise.Instrument.MAX_NUMBER_OF_PHRASES=2
  local ok,accepted=pcall(ctx.request_duplicate,ctx)
  renoise.Instrument.MAX_NUMBER_OF_PHRASES=capacity
  assert(ok and not accepted and log.count==0,"full instrument admitted a duplicate request")
  ctx:release_document()
end
print("acid_duplicate_label_spec: OK")
