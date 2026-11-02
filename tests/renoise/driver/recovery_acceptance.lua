local M={}
local FIXTURE_NAME="acceptance-recovery-labels.xrns"
local LABEL="Recovered bass"
local OUTPUT_POLICY="play_once"
local PB_RANGE=0
local SOURCE_LENGTH=4
local RECOVERED_KEY=7
local EDITED_KEY=9
local INSTRUMENT_NAME="Recovery label fixture"
local OWNED_LABEL="Pending owned bass"
local OWNED_OUTPUT_POLICY="repeat"
local OWNED_PB_RANGE=12
local OWNED_PITCH_SPAN=3
local OWNED_KEY=2
local OWNED_MASK_CLASS=3
local OWNED_REST_STEP=2
local OWNED_TIE_STEP=4

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

local function owned_pattern()
  local sequence=require("model.sequencer")
  local source=pattern(true,true)
  source.pitch_length=OWNED_PITCH_SPAN
  source.timing_mode="triplet"
  source.pitch_events[1]=sequence.new_pitch(OWNED_KEY,1,false,true)
  source.pitch_events[sequence.MAX_STEPS]=sequence.new_pitch(EDITED_KEY,-1,true,true)
  source.time_events[OWNED_REST_STEP]="R"
  source.time_events[OWNED_TIE_STEP]="T"
  source.time_events[sequence.MAX_STEPS]="R"
  for index=1,12 do source.scale_mask[index]=index==OWNED_MASK_CLASS end
  return source
end

local function context_for(song,delivery,on_request)
  local writer=require("writers.phrase_writer")
  local context=require("runtime.context").new({writer=writer,
    capture=function()return nil,"Recovery acceptance requires an installed editor" end,
    sink=function(request,done)
      on_request()
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
  local generation_requests=0
  local function requested() generation_requests=generation_requests+1 end
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
  local function assert_owned_draft(phrase)
    local source,policy,pb,label,custom=store.read_draft(song,instrument,phrase)
    assert(sequence.same_source(source,owned_pattern()) and policy==OWNED_OUTPUT_POLICY and
      pb==OWNED_PB_RANGE and label==OWNED_LABEL and custom,"Owned draft changed source/mask/label/settings")
  end
  local function assert_committed(phrase,expected_label)
    local source,policy,pb,label,custom=store.read_entry(song,ownership.id(phrase))
    local source_exact=sequence.same_source(source,pattern(false))
    assert(source_exact and policy==OUTPUT_POLICY and pb==PB_RANGE and label==expected_label and custom,
      string.format("Committed baseline mismatch: source_exact=%s policy=%s/%s pb=%s/%s label=%s/%s custom=%s/true",
        tostring(source_exact),tostring(policy),OUTPUT_POLICY,tostring(pb),tostring(PB_RANGE),
        tostring(label),expected_label,tostring(custom)))
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
          local before=helpers.baseline(song)
          local restored,restore_error=context:restore_editor_target(instrument,phrase)
          assert(restored,restore_error)
          assert(helpers.baseline(song)==before and generation_requests==1,
            "Owned target restoration generated or persisted")
          assert_committed(phrase,LABEL)
          assert(context:transition("edit",{source=owned_pattern(),output_policy=OWNED_OUTPUT_POLICY,
            pb_range=OWNED_PB_RANGE,label=OWNED_LABEL,label_custom=true}))
          assert_owned_draft(phrase)
          assert_committed(phrase,OWNED_LABEL)
          assert(generation_requests==1,"Owned draft edit generated output")
          local saved,reason=helpers.save(song,FIXTURE_NAME)
          assert(saved,reason)
          finish({status="PASS",roundtrip_fixture=FIXTURE_NAME,
            saved_baseline=helpers.baseline(song),target_id=ownership.id(phrase),
            custom_label=LABEL,mask_preserved=true,draft_preserved=true,owned_draft_preserved=true})
        end)
      end,requested)
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
      assert_committed(phrase,OWNED_LABEL)
      local draft,draft_policy,draft_pb,draft_label,draft_custom=store.read_draft(song,instrument,nil)
      assert(sequence.same_source(draft,pattern(true,true)) and draft_policy==OUTPUT_POLICY and
        draft_pb==PB_RANGE and draft_label==LABEL and draft_custom,
        "Cold scratch source/mask/label/settings changed")
      assert_owned_draft(phrase)
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
          assert_owned_draft(phrase)
          assert_committed(phrase,OWNED_LABEL)
          finish({status="PASS",reopened_baseline=reopened,target_id=id,
            read_only_restore=true,cold_process_required=true,source_mask_label_exact=true,
            recovered_generation_verified=true,original_phrase_preserved=true,
            owned_draft_source_settings_mask_label_exact=true,owned_restore_read_only=true})
        end)
      end,requested)
      local owned_restored,owned_error=context:restore_editor_target(instrument,phrase)
      assert(owned_restored,owned_error)
      local owned_editor=assert(context:editor_state())
      assert(sequence.same_source(owned_editor.source,owned_pattern()) and
        owned_editor.output_policy==OWNED_OUTPUT_POLICY and owned_editor.pb_range==OWNED_PB_RANGE and
        owned_editor.label==OWNED_LABEL and owned_editor.label_custom,
        "Cold owned editor restore lost draft values")
      assert(helpers.baseline(song)==reopened and generation_requests==0,
        "Cold owned restoration generated or persisted")
      local restored,reason=context:restore_editor_target(instrument,nil)
      assert(restored,reason)
      local editor=assert(context:editor_state())
      assert(sequence.same_source(editor.source,draft) and editor.label==LABEL and editor.label_custom,
        "Cold editor restore lost recovery metadata")
      assert(helpers.baseline(song)==reopened and generation_requests==0,
        "Cold restoration generated or wrote before explicit editing")
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
