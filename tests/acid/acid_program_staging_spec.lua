local fixture=dofile("tests/acid/runtime_phrase_fixture.lua")
local seq=require("model.sequencer")
local store=require("renoise.pattern_store")
local editor=require("model.editor_state")
local PITCH_COUNT,TIME_COUNT=3,4
local song,instrument=fixture.fixture()
local source=seq.new_pattern(TIME_COUNT)
source.pitch_length=PITCH_COUNT
for index=1,seq.MAX_STEPS do
  source.pitch_events[index]=seq.new_pitch(index%12,0,true,true)
  source.time_events[index]=index%2==0 and "R" or "N"
end
instrument.phrases={fixture.phrase(source,101),fixture.phrase(source,102)}
assert(store.save(song,101,source,"play_once",0))
assert(store.save(song,102,source,"play_once",0))
song.selected_instrument_index=1
song.selected_instrument=instrument
song.selected_phrase=instrument.phrases[1]
local function observable()
  local handlers={}
  return {add_notifier=function(_,fn)handlers[fn]=true end,
    has_notifier=function(_,fn)return handlers[fn]==true end,
    remove_notifier=function(_,fn)handlers[fn]=nil end,
    fire=function()
      local pending={};for fn in pairs(handlers)do pending[#pending+1]=fn end
      for _,fn in ipairs(pending)do if handlers[fn]then fn()end end
    end}
end
song.selected_phrase_observable=observable()
dofile("tests/acid/observer_host_fixture.lua").attach(song,observable)
local tool={app_new_document_observable=observable(),app_release_document_observable=observable(),
  app_idle_observable=observable(),tool_will_unload_observable=observable(),
  preferences={custom_scales={value=""}}}
local builder,dialog,answer
local prompts={}
local app={show_warning=function()end}
function app:show_prompt(title,message,buttons)
  prompts[#prompts+1]={title=title,message=message,buttons=buttons}
  local result=answer
  answer=nil
  return result or "Cancel"
end
function app:show_custom_dialog()
  dialog={visible=true,show=function()end,close=function(self)self.visible=false end}
  return dialog
end
renoise.song=function()return song end
renoise.tool=function()return tool end
renoise.app=function()return app end
renoise.ViewBuilder=function()
  builder={views={},nodes={}}
  setmetatable(builder,{__index=function(_,kind)return function(_,properties)
    local node={kind=kind,children={},notifiers={}}
    for key,value in pairs(properties or {})do node[key]=value end
    function node:add_child(child)self.children[#self.children+1]=child end
    function node:add_notifier(fn)self.notifiers[#self.notifiers+1]=fn end
    function node:fire(value)
      if value~=nil then self.value=value end
      if self.notifier then self.notifier(value)end
      for _,fn in ipairs(self.notifiers)do fn(value)end
    end
    if node.id then builder.views[node.id]=node end
    builder.nodes[#builder.nodes+1]=node
    return node
  end end})
  return builder
end
local writes,saves=0,0
local fail_saves=false
package.loaded["writers.phrase_writer"]={state=function()return "idle",nil end,
  is_temporary=function()return false end,release=function()end,
  create=function()writes=writes+1;return false,"fixture writer" end,
  regenerate=function()writes=writes+1;return false,"fixture writer" end}
local history
local new_history=editor.new_history
editor.new_history=function(...)
  history=new_history(...)
  return history
end
local write_draft=store.write_draft_metadata
store.write_draft_metadata=function(...)
  saves=saves+1
  if fail_saves then return nil,"injected draft save failure" end
  return write_draft(...)
end
local runtime
local context=require("runtime.context")
local new_context=context.new
context.new=function(...)
  runtime=new_context(...)
  return runtime
end
local gui=require("gui")
local function view(id)return assert(builder.views[id],"missing "..id)end
local function button(text)
  for _,node in ipairs(builder.nodes)do
    if node.kind=="button" and node.text==text then return node end
  end
  error("missing button "..text)
end
local function control(kind,width)
  for _,node in ipairs(builder.nodes)do
    if node.kind==kind and node.width==width then return node end
  end
  error("missing "..kind.." width "..width)
end
local function current()return history.states[history.position].pattern end
local function fire(id,value)view(id):fire(value)end
local function begin(memory)
  answer="Proceed"
  fire("acid_program_reenter_"..memory)
end
local function enter_all(count)
  fire("acid_program_restart")
  for _=1,count do fire("acid_program_enter")end
  assert(view("acid_program_finish").active,"all targets must be entered")
end
local function unchanged(before,revision,save_count,write_count)
  assert(seq.same_source(current(),before),"candidate leaked into source")
  assert(history.revision==revision,"candidate changed history")
  assert(saves==save_count,"candidate persisted a draft")
  assert(writes==write_count,"candidate generated output")
end
gui.show()
do
  local original=assert(seq.copy_source(current()))
  local initial_revision,initial_saves,initial_writes=history.revision,saves,writes
  local raw_store=song.tool_data
  assert(not view("acid_clipboard_paste").active)
  fire("acid_clipboard_copy")
  unchanged(original,initial_revision,initial_saves,initial_writes)
  assert(song.tool_data==raw_store,"Copy must not persist")
  fire("acid_clipboard_paste")
  unchanged(original,initial_revision,initial_saves,initial_writes)
  fire("acid_clipboard_scope",2)
  assert(not view("acid_clipboard_paste").active,"mismatched scope disables Paste")
  fire("acid_clipboard_paste")
  unchanged(original,initial_revision,initial_saves,initial_writes)
  fire("acid_clipboard_scope",1)
  fire("acid_program_key_05")
  local edited_revision,edited_saves=history.revision,saves
  fire("acid_clipboard_paste")
  assert(seq.same_source(current(),original),"Paste restores all captured pitches")
  assert(history.revision==edited_revision+1 and saves==edited_saves+1 and writes==initial_writes,
    "Paste must take exactly one ordinary source edit path")
  local pasted_revision,pasted_saves=history.revision,saves
  fire("acid_clipboard_paste")
  unchanged(original,pasted_revision,pasted_saves,initial_writes)
  for _,id in ipairs({"acid_clipboard_copy","acid_clipboard_paste"}) do
    begin("pitch")
    answer="Stay";fire(id)
    assert(view("acid_program_enter").active,"clipboard action must preserve stage on Stay")
    unchanged(original,pasted_revision,pasted_saves,initial_writes)
    answer="Discard";fire(id)
    assert(not view("acid_program_enter").active,"clipboard guard must discard on request")
    unchanged(original,pasted_revision,pasted_saves,initial_writes)
  end
end
assert(not view("acid_program_back").active and not view("acid_program_enter").active)
local before=seq.copy_source(current())
local revision,save_count,write_count=history.revision,saves,writes
answer="Cancel"
fire("acid_program_reenter_pitch")
unchanged(before,revision,save_count,write_count)
assert(not view("acid_program_enter").active,"cancel must leave Edit One")
begin("pitch")
local confirmation=prompts[#prompts]
assert(confirmation.message:find("P01",1,true) and confirmation.message:find("P03",1,true))
assert(not view("acid_program_finish").active)
fire("acid_program_select_time_02")
button("REST"):fire()
fire("acid_program_select_pitch_04")
assert(view("acid_program_pitch_summary").text:find("P01",1,true),"out-of-scope selector must be inert")
fire("acid_program_finish")
unchanged(before,revision,save_count,write_count)
fire("acid_program_select_pitch_03")
fire("acid_program_enter")
assert(not view("acid_program_finish").active,"final target alone cannot complete")
fire("acid_program_restart")
fire("acid_program_enter")
fire("acid_program_back")
fire("acid_program_key_01")
fire("acid_program_select_pitch_02")
fire("acid_program_enter")
assert(view("acid_program_finish").active,"no-change edit must retain entered marker")
fire("acid_program_select_pitch_01")
fire("acid_program_key_05")
assert(not view("acid_program_finish").active,"changed edit must invalidate its marker")
fire("acid_program_select_pitch_03")
fire("acid_program_enter")
assert(not view("acid_program_finish").active,"final Enter cannot hide another missing marker")
local prompt_count=#prompts
fire("acid_program_check")
unchanged(before,revision,save_count,write_count)
assert(not view("acid_program_finish").active,"Check must not mark missing targets")
assert(view("acid_status").text:find("Cannot generate: choose a pitch for step 1.",1,true),
  "Check must identify the first missing pitch position")
local project=editor.project
editor.project=function()return {error={message="coordinate free diagnostic"}}end
fire("acid_program_check")
editor.project=project
assert(view("acid_status").text:find("The edit could not be applied.",1,true) and
  not view("acid_status").text:find("coordinate free diagnostic",1,true),
  "Check maps coordinate-free projection failures without rendering diagnostic prose")
unchanged(before,revision,save_count,write_count)
fire("acid_editor_view",2)
assert(#prompts==prompt_count,"view navigation must not prompt")
assert(not view("acid_grid_key_02").active,"Grid editing is blocked while staging")
assert(view("acid_grid_pitch_01").tooltip:find("note="..before.pitch_events[1].note.." ",1,true),
  "Grid must display canonical source while Program has a candidate")
view("acid_grid_key_02"):fire()
unchanged(before,revision,save_count,write_count)
fire("acid_editor_view",1)
fire("acid_program_select_pitch_01")
fire("acid_program_enter")
assert(view("acid_program_finish").active)
fire("acid_program_finish")
assert(history.revision==revision+1 and saves==save_count+1 and writes==write_count,
  "Finish must apply exactly one history/draft edit")
local committed=current()
assert(committed.pitch_events[1].note==40)
for index=1,PITCH_COUNT do
  assert(not committed.pitch_events[index].accent and not committed.pitch_events[index].slide)
end
for index=PITCH_COUNT+1,seq.MAX_STEPS do
  assert(committed.pitch_events[index].note==before.pitch_events[index].note)
  assert(committed.pitch_events[index].accent and committed.pitch_events[index].slide)
end
for index=1,seq.MAX_STEPS do assert(committed.time_events[index]==before.time_events[index])end

before=seq.copy_source(current())
revision,save_count,write_count=history.revision,saves,writes
begin("time")
assert(not view("acid_program_key_02").active,"TIME staging cannot edit PITCH")
fire("acid_program_key_02")
button("TIE"):fire()
enter_all(TIME_COUNT)
fire("acid_program_finish")
assert(current().time_events[1]=="N","leading TIE must normalize")
for index=1,seq.MAX_STEPS do
  local left,right=current().pitch_events[index],before.pitch_events[index]
  assert(left.note==right.note and left.accent==right.accent and left.slide==right.slide)
  if index>TIME_COUNT then assert(current().time_events[index]==before.time_events[index])end
end
assert(history.revision==revision+1 and saves==save_count+1)
before=seq.copy_source(current())
revision,save_count,write_count=history.revision,saves,writes
begin("time")
enter_all(TIME_COUNT)
fire("acid_program_finish")
unchanged(before,revision,save_count,write_count)
assert(not view("acid_program_enter").active,"equal Finish closes stage")

begin("pitch")
enter_all(PITCH_COUNT)
revision,save_count,write_count=history.revision,saves,writes
answer="Finish"
button("Undo"):fire()
assert(history.revision==revision+1 and saves==save_count+1 and writes==write_count,
  "guard Finish must commit stage once and abandon Undo")
assert(current().pitch_events[1].note==36)
button("Undo"):fire()
assert(current().pitch_events[1].note==40,"Undo requires a fresh invocation")
begin("pitch")
answer="Discard"
button("Generate / Regenerate ACID Phrase"):fire()
assert(writes==write_count,"Discard must abandon Generate")
button("Generate / Regenerate ACID Phrase"):fire()
assert(writes==write_count+1,"Generate requires a fresh invocation")
write_count=writes

local actions={
  function()button("Undo"):fire()end,
  function()button("Redo"):fire()end,
  function()button("Reset Pattern"):fire()end,
  function()fire("acid_timing",2)end,
  function()fire("acid_output_policy",2)end,
  function()fire("acid_pb_range",2)end,
  function()control("valuebox",78):fire(TIME_COUNT+1)end,
  function()control("popup",78):fire(PITCH_COUNT+1)end,
  function()control("popup",360):fire(2)end,
  function()fire("acid_program_edit_one")end,
  function()fire("acid_program_reenter_pitch")end,
  function()fire("acid_program_reenter_time")end,
  function()button("Generate / Regenerate ACID Phrase"):fire()end,
  function()fire("acid_live_edit",true)end,
  function()button("Retry Live Edit"):fire()end
}
for _,complete in ipairs({false,true})do
  for _,decision in ipairs({"Stay","Discard","Finish"})do
    for _,action in ipairs(actions)do
      begin("time")
      fire("acid_program_select_time_02")
      button("REST"):fire()
      if complete then enter_all(TIME_COUNT)end
      before=seq.copy_source(current())
      local prior_settings=history.states[history.position]
      local prior_target=control("popup",360).value
      revision,save_count,write_count=history.revision,saves,writes
      local prior_prompts=#prompts
      answer=decision
      action()
      assert(#prompts==prior_prompts+1,"every guarded action must prompt")
      local changed_finish=complete and decision=="Finish"
      if changed_finish then
        local expected=seq.copy_source(before)
        expected.time_events[2]="R"
        assert(seq.same_source(current(),expected),"guard Finish may apply only candidate")
        assert(history.revision==revision+1 and saves==save_count+1 and writes==write_count,
          "changed guard Finish must make exactly one edit")
      else unchanged(before,revision,save_count,write_count)end
      local settings=history.states[history.position]
      assert(settings.output_policy==prior_settings.output_policy and settings.pb_range==prior_settings.pb_range,
        "guard must abandon requested output settings")
      assert(control("popup",360).value==prior_target,"guard must abandon target selection")
      assert(not view("acid_live_edit").value,"guard must abandon Live Edit toggle")
      local offered={};for _,choice in ipairs(prompts[#prompts].buttons)do offered[choice]=true end
      assert(offered.Stay and offered.Discard)
      assert((offered.Finish==true)==complete,"incomplete guard cannot offer Finish")
      local pending=decision=="Stay" or (not complete and decision=="Finish")
      assert(view("acid_program_enter").active==pending,"guard must resolve only stage")
      if pending then answer="Discard";fire("acid_program_edit_one")end
      if changed_finish then button("Undo"):fire()end
    end
  end
end

for _,complete in ipairs({false,true})do
  begin("pitch")
  if complete then enter_all(PITCH_COUNT)end
  local selected=instrument.phrases[2]
  prompt_count=#prompts
  song.selected_phrase=selected
  song.selected_phrase_observable:fire()
  tool.app_idle_observable:fire()
  assert(rawequal(song.selected_phrase,selected),"native selection must not be reversed")
  assert(#prompts==prompt_count,"external selection must not show a Finish guard")
  assert(not view("acid_program_enter").active,"external selection discards candidate")
  assert(writes==write_count)
  song.selected_phrase=instrument.phrases[1]
  song.selected_phrase_observable:fire()
  tool.app_idle_observable:fire()
end
begin("pitch")
enter_all(PITCH_COUNT)
local newer=seq.copy_source(current())
newer.pitch_events[1]=seq.new_pitch(7,0,true,false)
assert(runtime:transition("edit",{source=newer,output_policy="play_once",pb_range=0}))
revision=history.revision
fire("acid_program_finish")
assert(history.revision==revision,"stale Finish cannot overwrite revision")
assert(seq.same_source(runtime:editor_state().source,newer),"stale Finish cannot overwrite newer source")
assert(view("acid_program_enter").active,"stale Finish must retain stage")
prompt_count=#prompts
dialog:close()
tool.app_idle_observable:fire()
assert(#prompts==prompt_count,"dialog close discards without prompting")
gui.show()
assert(not view("acid_program_enter").active,"reopen cannot restore transient stage")
assert(not view("acid_clipboard_paste").active and view("acid_clipboard_status").text=="Clipboard empty",
  "reopen cannot restore session clipboard")
local drafts=require("runtime.draft_cache")
local function fresh(replacement)
  fail_saves=false
  tool.app_release_document_observable:fire()
  renoise.song=nil
  song,instrument=fixture.fixture()
  if replacement then
    instrument.phrases={fixture.phrase(replacement,101),fixture.phrase(replacement,102)}
    assert(store.save(song,101,replacement,"play_once",0))
    assert(store.save(song,102,replacement,"play_once",0))
  end
  renoise.song=function()return song end
  song.selected_instrument_index=1
  song.selected_instrument=instrument
  song.selected_phrase=instrument.phrases[1]
  dofile("tests/acid/observer_host_fixture.lua").attach(song,observable)
  gui.show()
end
do
  local project=editor.project
  for _,memory in ipairs({"pitch","time"}) do
    fresh(source)
    begin(memory)
    local before=assert(seq.copy_source(current()))
    local revision,save_count,write_count=history.revision,saves,writes
    fire("acid_program_finish")
    local count=memory=="pitch" and PITCH_COUNT or TIME_COUNT
    for position=1,count do
      local message=memory=="pitch" and "Cannot generate: choose a pitch for step %d." or
        "Cannot generate: enter timing for step %d."
      assert(view("acid_status").text==string.format(message,position),
        "entry feedback must identify the current first missing position")
      fire("acid_program_enter")
    end
    assert(view("acid_status").text=="" and view("acid_program_finish").active,
      "completing entry clears its missing-position issue before Finish")
    unchanged(before,revision,save_count,write_count)
  end
  editor.project=function(pattern,...)
    local projection=project(pattern,...)
    if pattern.pitch_events[1].key==source.pitch_events[1].key then
      projection.error={pitch_index=1,message="injected missing pitch detail"}
    end
    return projection
  end
  fresh(source)
  local write_count,save_count,revision=writes,saves,history.revision
  button("Generate / Regenerate ACID Phrase"):fire()
  local missing="Cannot generate: choose a pitch for step 1."
  assert(view("acid_status").text==missing and writes==write_count and saves==save_count,
    "projection failure blocks generation before a writer or save")
  fire("acid_clipboard_copy")
  fire("acid_editor_view",2)
  fire("acid_editor_view",1)
  assert(view("acid_status").text==missing and history.revision==revision,
    "Copy and navigation cannot clear unresolved pitch feedback")
  fire("acid_operation",2)
  fire("acid_operation_open")
  assert(view("acid_status").text==missing,"unrelated TIME operation cannot clear missing pitch feedback")
  local correction_saves,correction_revision=saves,history.revision
  fire("acid_program_key_05")
  assert(view("acid_status").text=="" and saves==correction_saves+1 and
    history.revision==correction_revision+1 and writes==write_count,
    "correcting the missing pitch clears its issue with one source edit and save")
  editor.project=project
end

do
  fresh(source)
  local revision,save_count,write_count=history.revision,saves,writes
  fire("acid_operation",9)
  fire("acid_operation_min_note",60)
  fire("acid_operation_max_note",24)
  fire("acid_operation_open")
  local failure="The operation could not be applied. Check its parameters."
  assert(view("acid_status").text==failure and saves==save_count and writes==write_count,
    "invalid random parameters report failure without saving or writing")
  fire("acid_operation",2)
  fire("acid_operation_open")
  assert(view("acid_status").text==failure,"an unrelated operation cannot clear random-pitch failure")
  fire("acid_operation",9)
  fire("acid_operation_max_note",60)
  local operation=seq.operation_candidate
  seq.operation_candidate=function(pattern,...)return assert(seq.copy_source(pattern))end
  local retry_saves,retry_revision=saves,history.revision
  fire("acid_operation_open")
  seq.operation_candidate=operation
  assert(view("acid_status").text=="" and saves==retry_saves and
    history.revision==retry_revision and writes==write_count,
    "successful same-result random retry clears its own error without history, save or write")
end

do
  fresh(source)
  fire("acid_clipboard_scope",3)
  fire("acid_clipboard_copy")
  local captured=assert(seq.copy_source(current()))
  local destination_choice=control("popup",360)
  destination_choice:fire(2)
  assert(view("acid_clipboard_paste").active,"clipboard must survive phrase selection")
  fire("acid_program_key_05")
  fire("acid_clipboard_paste")
  assert(seq.same_source(current(),captured),"cross-target paste must retain captured source")
  local writer_total=writes
  local raw_store=song.tool_data
  destination_choice:fire(#destination_choice.items)
  assert(runtime:target_state().kind=="new")
  assert(writes==writer_total and song.tool_data==raw_store,
    "selecting New with clipboard must not write or create")
  fire("acid_live_edit",true)
  assert(writes==writer_total,"arming New must wait for a real edit")
  fire("acid_clipboard_paste")
  assert(writes==writer_total+1,"armed New paste must use ordinary generation admission")
  assert(seq.same_source(current(),captured),"New paste must apply captured values")

  fresh(source)
  fire("acid_clipboard_copy")
  begin("pitch")
  enter_all(PITCH_COUNT)
  answer="Finish"
  fire("acid_clipboard_copy")
  assert(current().pitch_events[1].note==seq.BASE_NOTE)
  fire("acid_clipboard_paste")
  assert(current().pitch_events[1].note==source.pitch_events[1].note,
    "Finish guard must not automatically resume Copy")
  begin("pitch")
  enter_all(PITCH_COUNT)
  answer="Finish"
  fire("acid_clipboard_copy")
  fire("acid_clipboard_copy")
  fire("acid_program_key_05")
  fire("acid_clipboard_paste")
  assert(current().pitch_events[1].note==seq.BASE_NOTE,
    "explicit Copy after Finish must capture canonical post-Finish source")
end
local lifecycle_actions={
  selection=function()
    song.selected_phrase=instrument.phrases[2]
    song.selected_phrase_observable:fire()
  end,
  deletion=function()
    table.remove(instrument.phrases,1)
    song.selected_phrase=instrument.phrases[1]
    instrument.phrases_observable:fire()
    song.selected_phrase_observable:fire()
  end,
  ownership=function()
    song.selected_phrase.name="Foreign phrase"
    song.selected_phrase.name_observable:fire()
  end,
  close=function()dialog:close()end,
  document=function()tool.app_release_document_observable:fire()end,
  song=function()tool.app_new_document_observable:fire()end
}
for _,complete in ipairs({false,true})do
  for name,action in pairs(lifecycle_actions)do
    fresh()
    fire("acid_program_key_05")
    local canonical=seq.copy_source(current())
    local origin=song.selected_phrase
    local stored_before=seq.copy_source(assert(store.read_entry(song,101)))
    begin("pitch")
    if complete then enter_all(current().pitch_length)end
    local prompt_total,writer_total=#prompts,writes
    action()
    local selected=song.selected_phrase
    tool.app_idle_observable:fire()
    assert(#prompts==prompt_total,name.." must discard without modal")
    assert(writes==writer_total,name.." must never render candidate")
    assert(rawequal(song.selected_phrase,selected),name.." must not reverse native selection")
    assert(seq.same_source(assert(store.read_entry(song,101)),stored_before),name.." changed committed source")
    if name=="close" or name=="document" or name=="song" then
      gui.show()
      assert(not view("acid_program_enter").active,name.." cannot retain transient stage")
      local restored=assert(drafts.get(song,instrument,origin,runtime:draft_options()))
      assert(seq.same_source(restored,canonical),name.." must preserve canonical draft")
    else
      assert(not view("acid_program_enter").active,name.." must invalidate staged candidate")
      local message=view("acid_status").text
      assert(message:find("This entry is no longer available.",1,true) or
        message:find("Entry was discarded because the destination changed.",1,true),
        name.." must report transient entry discard after restoring canonical editor: "..message)
    end
  end
end
for _,complete in ipairs({false,true})do
  fresh()
  fail_saves=true
  fire("acid_program_key_06")
  local canonical=seq.copy_source(current())
  local origin=song.selected_phrase
  assert(drafts.has_volatile(song),"failed save must retain canonical recovery")
  begin("pitch")
  if complete then enter_all(current().pitch_length)end
  song.selected_phrase=instrument.phrases[2]
  song.selected_phrase_observable:fire()
  tool.app_idle_observable:fire()
  assert(not view("acid_program_enter").active,"failed canonical save cannot authorize stale stage")
  assert(drafts.has_volatile(song),"native switch must retain failed origin draft")
  assert(view("acid_status").text:find("Edits to the previous phrase could not be saved with the song.",1,true),
    "discard notice must retain canonical draft save warning")
  local recovered=assert(drafts.get(song,instrument,origin,runtime:draft_options()))
  assert(seq.same_source(recovered,canonical),"recoverable draft must be canonical, never candidate")
end
fail_saves=false
for _,complete in ipairs({false,true})do
  for _,drift in ipairs({"runtime","history"})do
    fresh()
    begin("pitch")
    if complete then enter_all(current().pitch_length)end
    newer=seq.copy_source(current())
    newer.pitch_events[1]=seq.new_pitch(7,0,true,false)
    if drift=="runtime" then
      assert(runtime:transition("edit",{source=newer,output_policy="play_once",pb_range=0}))
    else history:record(newer,"play_once",0)end
    revision,save_count,write_count=history.revision,saves,writes
    fire("acid_program_key_05")
    fire("acid_program_enter")
    fire("acid_program_finish")
    assert(history.revision==revision and saves==save_count and writes==write_count,
      "stale origin cannot authorize candidate editing or Finish")
    local actual=drift=="runtime" and runtime:editor_state().source or current()
    assert(seq.same_source(actual,newer),"stale stage must preserve newer canonical state")
    assert(view("acid_program_enter").active,"revision rejection must retain transient stage")
  end
end
for _,memory in ipairs({"pitch","time"})do
  fresh()
  begin(memory)
  fire("acid_program_select_"..memory.."_02")
  fire("acid_editor_view",2)
  if memory=="pitch" then
    fire("acid_pitch_page_2")
    fire("acid_grid_pitch_03")
  else
    fire("acid_time_page_2")
    fire("acid_grid_select_time_03")
  end
  fire("acid_editor_view",1)
  local summary=view(memory=="pitch" and "acid_program_pitch_summary" or "acid_program_time_summary")
  assert(summary.text:find(memory=="pitch" and "P02" or "TIME 02",1,true),
    "returning to Program must restore staged cursor and page")
  fire("acid_program_enter")
  assert(summary.text:find(memory=="pitch" and "P03" or "TIME 03",1,true),
    "Enter after Grid navigation must advance from displayed staged cursor")
end
fresh()
begin("pitch")
enter_all(current().pitch_length)
fire("acid_program_select_pitch_01")
fire("acid_program_key_05")
fire("acid_program_enter")
revision,save_count,write_count=history.revision,saves,writes
fail_saves=true
fire("acid_program_finish")
assert(history.revision==revision+1 and saves==save_count+1 and writes==write_count,
  "Finish save failure must retain one canonical edit without rendering")
assert(not view("acid_program_enter").active,"accepted Finish exits transient stage after save failure")
assert(current().pitch_events[1].note==40)
assert(drafts.has_volatile(song),"Finish save failure must preserve volatile draft")
local recovered=assert(drafts.get(song,instrument,song.selected_phrase,runtime:draft_options()))
assert(seq.same_source(recovered,current()),"Finish save failure recovery must contain whole accepted source")
fail_saves=false
fresh()
begin("pitch")
local project=editor.project
local diagnostic_position=2
editor.project=function(...)
  local projection=project(...)
  projection.error={message="injected candidate diagnostic",pitch_index=diagnostic_position}
  return projection
end
fire("acid_program_check")
local jump=button("Go to source error")
assert(jump.active,"candidate Check must enable coordinate navigation")
jump:fire()
fire("acid_program_enter")
assert(view("acid_program_select_pitch_02").text:find("+",1,true),
  "candidate diagnostic must move the staged cursor to its in-scope position")
local selected_summary=view("acid_program_pitch_summary").text
diagnostic_position=seq.MAX_STEPS+1
fire("acid_program_check")
jump:fire()
assert(view("acid_program_pitch_summary").text==selected_summary,
  "out-of-scope diagnostic must preserve staged cursor")
diagnostic_position=nil
fire("acid_program_check")
assert(not jump.active,"coordinate-free diagnostic must remain a message")
local newer=seq.copy_source(current())
newer.pitch_events[1]=seq.new_pitch(9,0,false,false)
assert(runtime:transition("edit",{source=newer,output_policy="play_once",pb_range=0}))
diagnostic_position=1
jump:fire()
assert(view("acid_program_pitch_summary").text==selected_summary,
  "stale diagnostic navigation must preserve staged cursor")
assert(view("acid_status").text:find("This entry is no longer available.",1,true),
  "stale diagnostic navigation must report invalid origin")
editor.project=project
local HIGHLIGHT=0xF0
local function highlighted(prefix,class)
  for index=1,12 do
    local color=view(string.format(prefix.."%02d",index)).color
    assert((color[1]==HIGHLIGHT)==(index==class+1),"resolved pitch-class highlight differs")
  end
end
local alternate=seq.new_pattern(TIME_COUNT)
alternate.pitch_events[1]=seq.new_pitch(12,0,true,true)
alternate.pitch_events[2]=seq.new_pitch(12,-1,true,true)
alternate.pitch_events[3]=seq.new_pitch(12,1,true,true)
fresh(alternate)
for position=1,3 do
  fire(string.format("acid_program_select_pitch_%02d",position))
  highlighted("acid_program_key_",0)
  assert(current().pitch_events[position].key==12,"navigation must preserve alternate raw key")
end
fire("acid_editor_view",2)
highlighted("acid_grid_key_",0)
assert(seq.same_source(current(),alternate),"resolved highlight cannot rewrite raw source")
local masked=seq.new_pattern(TIME_COUNT)
masked.scale_mask_enabled=true
for index=1,12 do masked.scale_mask[index]=index==1 or index==3 end
masked.pitch_events[1]=seq.new_pitch(3,0,true,true)
fresh(masked)
highlighted("acid_program_key_",2)
begin("pitch")
highlighted("acid_program_key_",0)
fire("acid_editor_view",2)
highlighted("acid_grid_key_",2)
fire("acid_editor_view",1)
highlighted("acid_program_key_",0)
fire("acid_program_key_05")
highlighted("acid_program_key_",2)
fire("acid_program_check")
highlighted("acid_program_key_",2)
assert(seq.same_source(current(),masked),"candidate resolution cannot rewrite canonical source")
local note_calls,timers={},{}
renoise.Track={TRACK_TYPE_SEQUENCER=1,TRACK_TYPE_MASTER=2,TRACK_TYPE_GROUP=4}
function tool:has_timer(callback)return timers[callback]~=nil end
function tool:add_timer(callback,interval)timers[callback]=interval end
function tool:remove_timer(callback)timers[callback]=nil end
song.selected_track={type=renoise.Track.TRACK_TYPE_SEQUENCER}
song.tracks={song.selected_track}
song.tracks_observable=observable()
song.selected_track_observable=observable()
function song:trigger_instrument_note_on(i,t,n,v)note_calls[#note_calls+1]={kind="on",note=n}end
function song:trigger_instrument_note_off(i,t,n)note_calls[#note_calls+1]={kind="off",note=n}end
fire("acid_audition")
assert(note_calls[#note_calls].note==38 and note_calls[#note_calls].kind=="on")
fire("acid_program_check")
assert(note_calls[#note_calls].kind=="off","Check releases audition")
fire("acid_audition")
fire("acid_program_pitch_page_2")
assert(note_calls[#note_calls].kind=="off","page navigation releases audition")
fire("acid_program_pitch_page_1")

fire("acid_program_key_09")
local before_audition=assert(seq.copy_source(current()))
local audition_writes,audition_saves=writes,saves
fire("acid_audition")
assert(note_calls[#note_calls].note==48,"PITCH audition resolves detached candidate")
assert(seq.same_source(before_audition,current()) and writes==audition_writes and saves==audition_saves)
answer="Discard";fire("acid_program_discard")
assert(note_calls[#note_calls].kind=="off","Discard releases before its prompt")
fire("acid_audition")
assert(note_calls[#note_calls].note==38,"canonical audition resolves mask")
begin("time")
assert(not view("acid_audition").active,"TIME staging disables audition")
local calls_before_time=#note_calls
fire("acid_audition")
assert(#note_calls==calls_before_time,"TIME-stage notifier cannot trigger audition")
answer="Discard";fire("acid_program_discard")
local function releases(action,label)
  fire("acid_audition")
  assert(note_calls[#note_calls].kind=="on",label.." onset")
  local count=#note_calls
  action()
  assert(#note_calls==count+1 and note_calls[#note_calls].kind=="off",label.." releases once")
  assert(next(timers)==nil,label.." detaches timer")
end
for _,id in ipairs({"acid_program_select_pitch_01","acid_program_select_time_01",
    "acid_pitch_page_1","acid_time_page_1","acid_program_time_page_1",
    "acid_decoded_next","acid_decoded_previous","acid_recovery_previous","acid_recovery_next",
    "acid_recovery_choice"}) do
  releases(function()fire(id)end,id)
end
releases(function()song.selected_track_observable:fire()end,"native track selection")
releases(function()song.selected_instrument_observable:fire()end,"native instrument selection")
releases(function()fire("acid_editor_view",2)end,"Grid switch")
releases(function()fire("acid_editor_view",1)end,"Program switch")
local prompt_impl=app.show_prompt
function app:show_prompt(...)
  assert(next(timers)==nil and note_calls[#note_calls].kind=="off","release precedes modal entry")
  return prompt_impl(self,...)
end
releases(function()begin("pitch")end,"Re-enter prompt")
releases(function()fire("acid_program_enter")end,"Enter navigation")
releases(function()fire("acid_program_back")end,"Back navigation")
releases(function()fire("acid_program_restart")end,"Restart navigation")
releases(function()answer="Stay";button("Undo"):fire()end,"pending-stage guard")
releases(function()answer="Discard";fire("acid_program_discard")end,"Discard prompt")
app.show_prompt=prompt_impl
local note_off=song.trigger_instrument_note_off
local failed_releases=0
function song:trigger_instrument_note_off(...)
  failed_releases=failed_releases+1
  error("injected note-off failure")
end
local cleanup_saves,cleanup_writes=saves,writes
fire("acid_audition")
fire("acid_editor_view",2)
local release_warning="Could not release the auditioned note. It may still be sounding."
assert(failed_releases==1 and next(timers)==nil and saves==cleanup_saves and writes==cleanup_writes,
  "failed navigation release attempts note-off once, detaches its timer and does not save or write")
assert(view("acid_status").text:find(release_warning,1,true) and
  not view("acid_status").text:find("injected note-off failure",1,true),
  "navigation reports audition cleanup failure without technical details")
fire("acid_editor_view",1)
assert(failed_releases==1 and view("acid_status").text:find(release_warning,1,true),
  "routine view navigation preserves audition cleanup failure")
song.trigger_instrument_note_off=note_off
local later_note_calls=#note_calls
fire("acid_audition")
assert(#note_calls==later_note_calls+1 and next(timers)~=nil,"another audition starts its own note")
fire("acid_editor_view",2)
assert(#note_calls==later_note_calls+2 and next(timers)==nil and
  view("acid_status").text:find(release_warning,1,true) and
  saves==cleanup_saves and writes==cleanup_writes,
  "a clean release of a new note cannot clear an unresolved release failure")
fire("acid_editor_view",1)
local note_on=song.trigger_instrument_note_on
function song:trigger_instrument_note_on(...)error("injected onset failure")end
fire("acid_audition")
song.trigger_instrument_note_on=note_on
assert(view("acid_status").text:find(release_warning,1,true),
  "a later onset failure cannot replace unresolved release evidence")
control("popup",360):fire(2)
assert(view("acid_status").text:find(release_warning,1,true) and
  saves==cleanup_saves and writes==cleanup_writes,
  "target switching preserves unresolved audition cleanup without saving or writing")
releases(function()dialog.visible=false;tool.app_idle_observable:fire()end,"dialog close")
gui.show()
assert(not view("acid_status").text:find(release_warning,1,true),"audition feedback has dialog lifetime")
releases(function()tool.app_release_document_observable:fire()end,"document release")
gui.show()
releases(function()tool.app_new_document_observable:fire()end,"new document")
gui.show()
releases(function()tool.tool_will_unload_observable:fire()end,"tool unload")
print("acid_program_staging_spec: OK")
