local M={}
local FIXTURE_NAME="acceptance-recovery-labels.xrns"
local LABEL="Recovered bass"
local OUTPUT_POLICY="play_once"
local PB_RANGE=0
local SOURCE_LENGTH=4
local RECOVERED_KEY=7
local EDITED_KEY=9
local INSTRUMENT_NAME="Recovery label fixture"

local function pattern(dirty,edited)
  local sequence=require("model.sequencer")
  local source=sequence.new_pattern(SOURCE_LENGTH)
  source.pitch_length=SOURCE_LENGTH
  source.scale_mask_enabled=true
  for index=1,12 do source.scale_mask[index]=index==1 or index==5 end
  if dirty then source.pitch_events[1]=sequence.new_pitch(RECOVERED_KEY,0,true,false) end
  if edited then source.pitch_events[2]=sequence.new_pitch(EDITED_KEY,0,false,false) end
  return source
end

local function context_for(song,delivery)
  local writer=require("writers.phrase_writer")
  local context=require("runtime.context").new({writer=writer,
    capture=function()return nil,"Recovery acceptance requires an installed editor" end,
    sink=function(request,done)
      if request.kind=="create" then return writer.create(request,done) end
      return writer.regenerate(request,done)
    end,cancel=writer.cancel})
  context:attach_document(song)
  context:open_dialog(delivery)
  return context
end

function M.run(case_name,done,helpers)
  local song=renoise.song()
  local sequence=require("model.sequencer")
  local ownership=require("renoise.phrase_ownership")
  local store=require("renoise.pattern_store")
  local drafts=require("runtime.draft_cache")
  local instrument=song.selected_instrument
  local context,finished
  local reopened
  local function finish(result)
    if finished then return end
    finished=true
    if context then context:release_document() end
    result.case=case_name
    done(result)
  end
  local function checked(action)
    local ok,reason=pcall(action)
    if not ok then finish({status="FAIL",reason=tostring(reason)}) end
    return ok
  end
  local function edit(source)
    assert(context:transition("edit",{source=source,output_policy=OUTPUT_POLICY,
      pb_range=PB_RANGE,label=LABEL,label_custom=true}))
  end
  local function copy_recovery(phrase)
    assert(drafts.detach(song,instrument,phrase,"Recovery acceptance source"))
    local entries=assert(context:recovery_entries())
    local entry=assert(entries[#entries],"Recovery source unavailable")
    assert(context:copy_recovery_to_new(entry.token,entry.revision))
    local editor=assert(context:editor_state())
    assert(editor.label==LABEL and editor.label_custom,"Recovery copy changed label")
  end
  if case_name=="recovery-labels-prepare" then
    checked(function()
      assert(instrument and #instrument.phrases==0,"Recovery fixture requires an empty instrument")
      instrument.name=INSTRUMENT_NAME
      assert(not song.transport.playing,"Stop playback before recovery acceptance")
      context=context_for(song,function(result)
        checked(function()
          assert(result.kind=="success" and result.verified and result.phrase,
            result.message or result.reason or "Initial native generation failed")
          local phrase=result.phrase
          edit(pattern(true))
          copy_recovery(phrase)
          edit(pattern(true,true))
          local source,policy,pb,label,custom=store.read_draft(song,instrument,nil)
          assert(sequence.same_source(source,pattern(true,true)) and policy==OUTPUT_POLICY and
            pb==PB_RANGE and label==LABEL and custom,"Recovery scratch was not saved exactly")
          local saved,reason=helpers.save(song,FIXTURE_NAME)
          assert(saved,reason)
          finish({status="PASS",roundtrip_fixture=FIXTURE_NAME,
            saved_baseline=helpers.baseline(song),target_id=ownership.id(phrase),
            custom_label=LABEL,mask_preserved=true,draft_preserved=true})
        end)
      end)
      assert(context:bind_new(instrument))
      edit(pattern(false))
      local accepted,reason=context:request_generation("manual")
      assert(accepted,reason)
    end)
  elseif case_name=="recovery-labels-cold" then
    checked(function()
      reopened=helpers.baseline(song)
      assert(instrument and #instrument.phrases==1,"Cold fixture phrase inventory changed")
      local phrase=instrument.phrases[1]
      local id=assert(ownership.id(phrase))
      local source,policy,pb,label,custom=store.read_entry(song,id)
      assert(sequence.same_source(source,pattern(false)) and policy==OUTPUT_POLICY and
        pb==PB_RANGE and label==LABEL and custom,"Cold committed source or metadata changed")
      local draft,draft_policy,draft_pb,draft_label,draft_custom=store.read_draft(song,instrument,nil)
      assert(sequence.same_source(draft,pattern(true,true)) and draft_policy==OUTPUT_POLICY and
        draft_pb==PB_RANGE and draft_label==LABEL and draft_custom,
        "Cold scratch source/mask/label/settings changed")
      local snapshot=assert(ownership.snapshot(phrase))
      context=context_for(song,function(result)
        checked(function()
          assert(result.kind=="success" and result.verified and result.phrase,
            result.message or result.reason or "Recovered native generation failed")
          assert(#instrument.phrases==2 and not rawequal(result.phrase,phrase),
            "Recovered generation did not create a separate phrase")
          local generated_id=assert(ownership.id(result.phrase))
          local generated,generated_policy,generated_pb,generated_label,generated_custom=
            store.read_entry(song,generated_id)
          assert(sequence.same_source(generated,pattern(true,true)) and generated_policy==OUTPUT_POLICY
            and generated_pb==PB_RANGE and generated_label==LABEL and generated_custom,
            "Recovered generation changed source or metadata")
          assert(ownership.compare(snapshot,assert(ownership.snapshot(phrase))),
            "Recovered generation changed original phrase")
          local resolved=assert(sequence.prepare_resolution(generated)).resolved_records
          assert(result.phrase:line(1):note_column(1).note_value==resolved[1].note,
            "Recovered native pitch differs from shared resolution")
          assert(store.read_draft(song,instrument,nil)==nil,"Recovered New draft was not consumed")
          finish({status="PASS",reopened_baseline=reopened,target_id=id,
            read_only_restore=true,cold_process_required=true,source_mask_label_exact=true,
            recovered_generation_verified=true,original_phrase_preserved=true})
        end)
      end)
      local restored,reason=context:restore_editor_target(instrument,nil)
      assert(restored,reason)
      local editor=assert(context:editor_state())
      assert(sequence.same_source(editor.source,draft) and editor.label==LABEL and editor.label_custom,
        "Cold editor restore lost recovery metadata")
      assert(helpers.baseline(song)==reopened,"Cold restoration wrote before explicit editing")
      copy_recovery(nil)
      edit(pattern(true,true))
      local accepted,generation_error=context:request_generation("manual")
      assert(accepted,generation_error)
    end)
  else
    finish({status="ERROR",reason="Unknown recovery acceptance case"})
  end
  return true
end

return M
