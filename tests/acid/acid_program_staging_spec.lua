local fixture=dofile("tests/acid/runtime_phrase_fixture.lua")
local seq=require("model.sequencer")
local store=require("renoise.pattern_store")
local editor=require("model.editor_state")
local PITCH_COUNT,TIME_COUNT=3,4
local LONG_ENTRY_COUNT,MISSING_POSITION=20,5
local PAGE_SIZE=seq.PAGE_SIZE
local SELECTED_COLOR=0xF0
local ACCEPTED_PITCH_NAME,CANDIDATE_PITCH_NAME="C#3","E3"
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
  local parent_by_child={}
  local default_size={width=0,height=0}
  local sizes=setmetatable({},{__mode="k"})
  local function add_view(parent,child)
    if parent_by_child[child] then error("view already has a parent") end
    parent.views[#parent.views+1]=child;parent_by_child[child]=parent
  end
  local function remove_view(parent,child)
    for index,current in ipairs(parent.views) do
      if rawequal(current,child) then table.remove(parent.views,index);parent_by_child[child]=nil;return end
    end
    error("view is not a child")
  end
  setmetatable(builder,{__index=function(_,kind)return function(_,properties)
    local node={kind=kind,views={},notifiers={}}
    setmetatable(node,{__index=function(view,key)
      if key=="size" then return sizes[view] or default_size end
    end,__newindex=function(view,key,value)
      if key=="size" then sizes[view]=value~=default_size and value or nil
      else rawset(view,key,value) end
    end})
    node.children=node.views
    for key,value in pairs(properties or {})do
      if type(key)=="number"then add_view(node,value)else node[key]=value end
    end
    function node:add_view(child)add_view(self,child)end
    function node:remove_view(child)remove_view(self,child)end
    node.add_child=node.add_view;node.remove_child=node.remove_view
    function node:add_notifier(fn)self.notifiers[#self.notifiers+1]=fn end
    function node:update()
      assert(self.kind=="canvas")
      self.outlined=false
      self.render({size=self.size,stroke_rect=function() self.outlined=true end})
    end
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
local function cancel_stage(decision)
  answer=decision
  fire("acid_program_discard")
end
local function select_stage_position(memory,position)
  local page=math.floor((position-1)/PAGE_SIZE)+1
  local cell=(position-1)%PAGE_SIZE+1
  fire("acid_program_"..memory.."_page_"..page)
  fire(string.format("acid_program_select_%s_%02d",memory,cell))
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
assert(builder.views.acid_program_edit_one==nil and
  view("acid_program_reenter_pitch").text=="Enter pitches" and
  view("acid_program_reenter_time").text=="Enter timing",
  "entry launches replace Edit One with contextual labels")
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
    answer="Cancel";fire(id)
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
assert(not view("acid_program_enter").active,"cancel must remain in normal editing")
begin("pitch")
local confirmation=prompts[#prompts]
assert(confirmation.message:find("P01",1,true) and confirmation.message:find("P03",1,true))
for _,term in ipairs({"origin","candidate","revision","transaction"}) do
  assert(not confirmation.message:lower():find(term,1,true),"ordinary entry prompt hides internal term: "..term)
end
assert(view("acid_program_restart").text=="Restart" and view("acid_program_discard").text=="Cancel")
assert(not view("acid_program_finish").active)
fire("acid_program_select_time_02")
button("REST"):fire()
fire("acid_program_select_pitch_04")
assert(view("acid_program_select_pitch_01").text=="P01" and
  view("acid_program_select_pitch_01".."_selection").outlined,
  "out-of-scope selector must leave the selected PITCH position unchanged")
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
unchanged(before,revision,save_count,write_count)
fire("acid_editor_view",2)
assert(#prompts==prompt_count,"view navigation must not prompt")
assert(not view("acid_grid_key_02").active,"Grid editing is blocked while staging")
assert(seq.same_source(current(),before) and
  view("acid_grid_pitch_01").text:find(ACCEPTED_PITCH_NAME,1,true) and
  view("acid_grid_pitch_01").tooltip:find(ACCEPTED_PITCH_NAME,1,true) and
  view("acid_program_select_pitch_01").tooltip:find(CANDIDATE_PITCH_NAME,1,true),
  "Grid displays the resolved accepted pitch while Program has a different candidate")
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
answer="Cancel"
button("Generate"):fire()
assert(writes==write_count,"Cancel must abandon Generate")
button("Generate"):fire()
assert(writes==write_count+1,"Generate requires a fresh invocation")
write_count=writes

local actions={
  function()button("Undo"):fire()end,
  function()button("Redo"):fire()end,
  function()view("acid_pattern_reset"):fire()end,
  function()fire("acid_timing",2)end,
  function()fire("acid_output_policy",2)end,
  function()fire("acid_pb_range",2)end,
  function()control("valuebox",78):fire(TIME_COUNT+1)end,
  function()control("popup",78):fire(PITCH_COUNT+1)end,
  function()control("popup",360):fire(2)end,
  function()fire("acid_program_reenter_pitch")end,
  function()fire("acid_program_reenter_time")end,
  function()button("Generate"):fire()end,
  function()fire("acid_live_edit",true)end
}
for _,complete in ipairs({false,true})do
  for _,decision in ipairs({"Stay","Cancel","Finish"})do
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
      assert(offered.Stay and offered.Cancel)
      assert((offered.Finish==true)==complete,"incomplete guard cannot offer Finish")
      local pending=decision=="Stay" or (not complete and decision=="Finish")
      assert(view("acid_program_enter").active==pending,"guard must resolve only stage")
      if pending then answer="Cancel";fire("acid_program_reenter_pitch")end
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
assert(not view("acid_program_enter").active,"stale Finish discards the invalid stage")
assert(view("acid_status").text=="The destination changed. Start entry again.",
  "stale entry reports a concise destination message")
prompt_count=#prompts
dialog:close()
tool.app_idle_observable:fire()
assert(#prompts==prompt_count,"dialog close discards without prompting")
gui.show()
assert(not view("acid_program_enter").active,"reopen cannot restore transient stage")
assert(not view("acid_clipboard_paste").active and builder.views.acid_clipboard_status==nil,
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
  local long_source=seq.new_pattern(TIME_COUNT)
  long_source.pitch_length=LONG_ENTRY_COUNT
  for index=1,seq.MAX_STEPS do
    long_source.pitch_events[index]=seq.new_pitch(index%12,0,true,true)
    long_source.time_events[index]=index%2==0 and "R" or "N"
  end
  fresh(long_source)
  local canonical=seq.copy_source(current())
  local revision_before,saves_before,writes_before=history.revision,saves,writes
  begin("pitch")
  assert(view("acid_program_stage_status").text=="Pitch 1 of 20")
  for position=1,LONG_ENTRY_COUNT do
    if position~=MISSING_POSITION then
      select_stage_position("pitch",position)
      fire("acid_program_enter")
    end
  end
  select_stage_position("pitch",17)
  fire("acid_program_enter")
  assert(view("acid_program_stage_status").text=="Pitch 18 of 20",
    "progress follows the cursor after skipping an unentered target")
  answer="Stay"
  button("Generate"):fire()
  assert(view("acid_program_select_pitch_05".."_selection").outlined and
    view("acid_program_stage_status").text=="Pitch 5 of 20" and
    view("acid_program_pitch_page_1").color[1]==SELECTED_COLOR,
    "blocked Program Generate returns to page one and reveals the first missing position")
  unchanged(canonical,revision_before,saves_before,writes_before)
  fire("acid_editor_view",2)
  assert(view("acid_program_stage_status").text:find("return to Program",1,true),
    "Grid feedback directs the user to Program while retaining stage progress")
  answer="Stay"
  button("Generate"):fire()
  assert(view("acid_editor_view").value==2 and view("acid_program_stage_status").text:find("return to Program",1,true),
    "blocked Grid Generate stays in Grid and explains where to edit")
  unchanged(canonical,revision_before,saves_before,writes_before)
  fire("acid_editor_view",1)
  assert(view("acid_program_select_pitch_05".."_selection").outlined and
    view("acid_program_stage_status").text=="Pitch 5 of 20",
    "returning to Program restores the missing cursor")
  assert(not view("acid_program_finish").active)
  fire("acid_program_finish")
  unchanged(canonical,revision_before,saves_before,writes_before)
  for _=1,LONG_ENTRY_COUNT do fire("acid_program_enter")end
  assert(view("acid_program_finish").active)
  select_stage_position("pitch",LONG_ENTRY_COUNT)
  view("acid_program_key_05"):fire()
  assert(not view("acid_program_finish").active,"candidate edit invalidates its entered marker")
  local candidate_revision,candidate_saves,candidate_writes=history.revision,saves,writes
cancel_stage("Cancel")
  unchanged(canonical,candidate_revision,candidate_saves,candidate_writes)
  assert(not view("acid_program_enter").active and view("acid_program_discard").text=="Cancel",
    "Cancel discards the candidate stage")

  fresh(long_source)
  begin("pitch")
  fire("acid_program_key_05")
  enter_all(LONG_ENTRY_COUNT)
  fire("acid_program_restart")
  assert(view("acid_program_finish").active and view("acid_program_stage_status").text=="Pitch 1 of 20",
    "Restart resets only the cursor and preserves every entered marker")
  fire("acid_editor_view",2)
  assert(view("acid_program_finish").active and view("acid_program_discard").active,
    "Finish and Cancel remain reachable in Grid after complete entry")
  revision_before,saves_before,writes_before=history.revision,saves,writes
  fire("acid_program_finish")
  assert(history.revision==revision_before+1 and saves==saves_before+1 and writes==writes_before,
    "Finish from Grid commits the complete candidate once")

  fresh(long_source)
  begin("pitch")
  fire("acid_program_key_05")
  fire("acid_editor_view",2)
  revision_before,saves_before,writes_before=history.revision,saves,writes
cancel_stage("Cancel")
  unchanged(canonical,revision_before,saves_before,writes_before)
  assert(not view("acid_program_enter").active,"Cancel from Grid abandons the staged candidate")

  local time_source=seq.new_pattern(MISSING_POSITION)
  time_source.pitch_length=PITCH_COUNT
  for index=1,seq.MAX_STEPS do
    time_source.pitch_events[index]=seq.new_pitch(index%12,0,true,true)
    time_source.time_events[index]=index%2==0 and "R" or "N"
  end
  fresh(time_source)
  local time_before=seq.copy_source(current())
  revision_before,saves_before,writes_before=history.revision,saves,writes
  begin("time")
  for position=1,MISSING_POSITION do
    if position~=MISSING_POSITION then
      select_stage_position("time",position)
      fire("acid_program_enter")
    end
  end
  answer="Stay"
  button("Generate"):fire()
  assert(view("acid_program_select_time_05".."_selection").outlined and
    view("acid_program_stage_status").text=="Timing 5 of 5" and
    view("acid_program_time_page_1").color[1]==SELECTED_COLOR,
    "blocked TIME Generate reveals the first missing position: "..
      view("acid_program_stage_status").text)
  unchanged(time_before,revision_before,saves_before,writes_before)
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
  button("Generate"):fire()
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
  local editor_builder=builder
  assert(view("acid_clipboard_paste").active,"matching clipboard starts eligible")
  fire("acid_label_rename")
  assert(editor_builder.views.acid_clipboard_paste.active==false,"open rename dialog gates Paste")
  fire("acid_label_discard")
  assert(editor_builder.views.acid_clipboard_paste.active==true,
    "discarded rename restores Paste eligibility")
  editor_builder.views.acid_label_rename:fire()
  local native_label_dialog=dialog
  native_label_dialog:close()
  assert(editor_builder.views.acid_clipboard_paste.active==false,
    "native close remains gated until idle refresh")
  tool.app_idle_observable:fire()
  assert(editor_builder.views.acid_clipboard_paste.active==true,
    "idle refresh releases the native-close guard")
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
      assert(message:find("The destination changed. Start entry again.",1,true) and
        not message:lower():find("origin",1,true) and not message:lower():find("revision",1,true),
        name.." must report a concise destination change after restoring canonical editor: "..message)
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
    "the verified origin draft failure remains phrase-scoped")
  local recovered=assert(drafts.get(song,instrument,origin,runtime:draft_options()))
  assert(seq.same_source(recovered,canonical),"recoverable draft must be canonical, never candidate")
end
fail_saves=false
fresh(source)
begin("pitch")
local has_volatile=drafts.has_volatile
drafts.has_volatile=function(candidate)
  assert(rawequal(candidate,song))
  return true
end
song.selected_phrase=instrument.phrases[2]
song.selected_phrase_observable:fire()
tool.app_idle_observable:fire()
drafts.has_volatile=has_volatile
assert(view("acid_status").text:find("Some edits could not be saved with this song.",1,true) and
  not view("acid_status").text:find("previous phrase",1,true),
  "native selection uses song-scoped wording when only song-wide volatile evidence exists")
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
    assert(not view("acid_program_enter").active and
      view("acid_status").text=="The destination changed. Start entry again.",
      "stale revision discards transient entry with a concise destination message")
  end
end
for _,memory in ipairs({"pitch","time"})do
  fresh()
  begin(memory)
  fire("acid_program_enter")
  fire("acid_program_select_"..memory.."_02")
  local markers={}
  for cell=1,PAGE_SIZE do
    markers[cell]=view(string.format("acid_program_select_%s_%02d",memory,cell)).text
  end
  fire("acid_editor_view",2)
  for _,action in ipairs({"back","enter","restart"}) do
    assert(not view("acid_program_"..action).active,"Grid disables entry navigation")
    fire("acid_program_"..action)
  end
  for _=1,seq.MAX_STEPS do fire("acid_program_enter") end
  assert(not view("acid_program_finish").active,"Grid callbacks cannot complete entry")
  if memory=="pitch" then
    fire("acid_pitch_page_2")
    fire("acid_grid_pitch_03")
  else
    fire("acid_time_page_2")
    fire("acid_grid_select_time_03")
  end
  fire("acid_editor_view",1)
  for cell=1,PAGE_SIZE do
    assert(view(string.format("acid_program_select_%s_%02d",memory,cell)).text==markers[cell],
      "Grid callbacks preserve entered markers")
  end
  local selector=view("acid_program_select_"..memory.."_02")
  assert(view(selector.id.."_selection").outlined,
    "returning to Program must restore the staged cursor and page")
  fire("acid_program_enter")
  assert(view("acid_program_select_"..memory.."_03_selection").outlined,
    "Enter after Grid navigation must advance the staged cursor")
  local count=memory=="pitch" and current().pitch_length or current().length
  for _=3,count do fire("acid_program_enter") end
  assert(view("acid_program_finish").active,"Grid callbacks preserve previously entered positions")
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
do
  local source=seq.new_pattern(8)
  source.pitch_length=16
  source.time_events[2]="T"
  source.pitch_events[1]=seq.new_pitch(4,-1)
  source.pitch_events[2]=seq.new_pitch(4,1)
  source.length=4
  fresh(source)
  fire("acid_last_step",8)
  assert(view("acid_program_time_reference_01").text=="P01")
  assert(view("acid_program_time_reference_02").text=="P01 hold")
  assert(view("acid_program_time_reference_03").text=="P02")
  assert(view("acid_program_time_reference_08").text=="P07")
  assert(view("acid_program_time_reference_09").text=="")
  assert(view("acid_program_select_time_09").text=="09 Note")
  assert(view("acid_program_select_pitch_07").color[1]==0x55 and
    view("acid_program_select_pitch_08").color[1]==0x49 and
    view("acid_program_select_time_09").color[1]==0x30,
    "used pitch slots and inactive time positions retain distinct fills")
  local before,revision,save_count,write_count=seq.copy_source(current()),history.revision,saves,writes
  fire("acid_program_select_time_03")
  assert(view("acid_program_select_time_03_selection").outlined and
    view("acid_program_select_pitch_02_selection").outlined and
    view("acid_selection_mapping").text=="T03 → P02 · E4")
  assert(view("acid_program_select_time_03").color[1]==0xBD,
    "selection keeps the NOTE event color")
  fire("acid_program_select_pitch_01")
  assert(view("acid_program_select_time_01_selection").outlined and
    view("acid_program_select_time_02_selection").outlined and
    not view("acid_program_select_time_03_selection").outlined,
    "pitch selection links both its attack and held time steps")
  fire("acid_editor_view",2)
  assert(view("acid_grid_mapping_01").text=="P01 · E2" and
    view("acid_grid_mapping_02").text=="P01 hold" and
    view("acid_grid_mapping_03").text=="P02 · E4")
  assert(view("acid_grid_select_time_02_selection").outlined and
    view("acid_grid_select_time_09").color[1]==0x30 and
    view("acid_grid_mapping_09").text=="INACTIVE")
  fire("acid_grid_select_time_03")
  assert(view("acid_grid_pitch_02_selection").outlined and
    view("acid_grid_select_time_03_selection").outlined)
  fire("acid_editor_view",1)
  unchanged(before,revision,save_count,write_count)
  fire("acid_program_select_time_02")
  button("REST"):fire()
  assert(view("acid_program_time_reference_02").text=="--" and
    not view("acid_program_select_pitch_01_selection").outlined and
    view("acid_selection_mapping").text=="T02 · Rest")
  button("Undo"):fire()
  assert(view("acid_program_time_reference_02").text=="P01 hold" and
    view("acid_program_select_pitch_01_selection").outlined,
    "Undo restores both mapping and linked selection")
  begin("time")
  fire("acid_program_select_time_02")
  button("REST"):fire()
  assert(view("acid_program_time_reference_02").text=="--" and
    current().time_events[2]=="T","Program maps its pending timing candidate")
  fire("acid_editor_view",2)
  assert(view("acid_grid_mapping_02").text=="P01 hold",
    "Grid maps canonical timing during staged entry")
  fire("acid_editor_view",1)
  cancel_stage("Cancel")
  assert(view("acid_program_time_reference_02").text=="P01 hold")

  source=seq.new_pattern(4)
  source.pitch_length=32
  fresh(source)
  fire("acid_last_step",32)
  before,revision,save_count,write_count=seq.copy_source(current()),history.revision,saves,writes
  fire("acid_program_time_page_2")
  fire("acid_program_select_time_01")
  assert(view("acid_program_select_pitch_01").text=="P17" and
    view("acid_program_select_pitch_01_selection").outlined and
    view("acid_selection_mapping").text=="T17 → P17 · C3",
    "TIME selection reveals a linked pitch on the other page")
  unchanged(before,revision,save_count,write_count)
  source.pitch_length=2
  fresh(source)
  fire("acid_last_step",32)
  fire("acid_program_select_pitch_01")
  assert(view("acid_program_select_time_01_selection").outlined and
    view("acid_program_select_time_03_selection").outlined and
    not view("acid_program_select_time_02_selection").outlined,
    "wrapped pitches link all corresponding notes")
  fire("acid_program_time_page_2")
  assert(view("acid_program_select_time_01_selection").outlined and
    view("acid_program_time_reference_01").text=="P01",
    "pitch links extend across timing pages")
end
do
  local source=seq.new_pattern(4)
  source.pitch_length=3
  source.pitch_events[1]=seq.new_pitch(4,0)
  source.pitch_events[2]=seq.new_pitch(7,0)
  source.time_events[2]="T"
  fresh(source)
  fire("acid_program_select_pitch_01")
  fire("acid_program_slide",true)
  assert(view("acid_program_select_pitch_01").text=="P01 SLD→")
  assert(view("acid_program_time_reference_01").text=="P01 →" and
    view("acid_program_time_reference_02").text=="P01 hold →" and
    view("acid_program_time_reference_03").text=="↗ P02")
  local before,revision,save_count,write_count=seq.copy_source(current()),history.revision,saves,writes
  fire("acid_program_select_time_03")
  assert(view("acid_program_select_pitch_01_selection").outlined and
    view("acid_program_select_pitch_02_selection").outlined and
    view("acid_program_select_time_01_selection").outlined and
    view("acid_program_select_time_02_selection").outlined and
    view("acid_program_select_time_03_selection").outlined and
    not view("acid_program_select_time_04_selection").outlined)
  assert(view("acid_selection_mapping").text==
    "Slide: T01 / P01 E3 → T03 / P02 G3 · via T02")
  assert(not view("acid_program_slide").value,
    "the incoming slide still edits the destination pitch controls")
  fire("acid_editor_view",2)
  assert(view("acid_grid_pitch_01").text=="E3 SLD→" and
    view("acid_grid_mapping_01").text=="P01 · E3 →" and
    view("acid_grid_mapping_02").text=="P01 hold →" and
    view("acid_grid_mapping_03").text=="↗ P02 · G3")
  assert(view("acid_grid_pitch_01_selection").outlined and
    view("acid_grid_pitch_02_selection").outlined and
    view("acid_grid_select_time_02_selection").outlined)
  fire("acid_editor_view",1)
  unchanged(before,revision,save_count,write_count)
  fire("acid_program_select_time_02")
  button("REST"):fire()
  assert(view("acid_program_select_pitch_01").text=="P01 SLD" and
    view("acid_program_time_reference_01").text=="P01" and
    view("acid_program_time_reference_03").text=="P02",
    "REST keeps the stored flag visible without claiming a connection")
  fire("acid_program_select_pitch_01")
  assert(view("acid_selection_mapping").text:find("Slide: blocked by T02 Rest",1,true))
  button("Undo"):fire()
  assert(view("acid_program_select_pitch_01").text=="P01 SLD→" and
    view("acid_program_time_reference_03").text=="↗ P02")
  begin("time")
  fire("acid_program_select_time_02")
  button("REST"):fire()
  assert(view("acid_program_time_reference_03").text=="P02")
  fire("acid_editor_view",2)
  assert(view("acid_grid_mapping_03").text=="↗ P02 · G3")
  fire("acid_editor_view",1)
  cancel_stage("Cancel")
  assert(view("acid_program_time_reference_03").text=="↗ P02")

  fire("acid_program_select_pitch_03")
  fire("acid_program_slide",true)
  fire("acid_output_policy",2)
  assert(view("acid_program_time_reference_01").text=="↗↻ P01 →" and
    view("acid_program_time_reference_04").text=="P03 →↻")
  fire("acid_program_select_time_04")
  assert(view("acid_selection_mapping").text:find("next cycle T01",1,true))
  fire("acid_output_policy",1)
  assert(view("acid_program_time_reference_01").text=="P01 →" and
    view("acid_program_time_reference_04").text=="P03" and
    view("acid_selection_mapping").text:find("Slide: ends at pattern boundary",1,true),
    "Play Once removes seam arrows and describes the stored terminal Slide flag")
end
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
local function contains(parent,target)
  for _,child in ipairs(parent.views or {})do
    if rawequal(child,target) or contains(child,target)then return true end
  end
  return false
end
local program_audition,grid_audition=view("acid_audition"),view("acid_grid_audition")
local audition_constructors=0
for _,node in ipairs(builder.nodes)do
  if node.id=="acid_audition" or node.id=="acid_grid_audition"then audition_constructors=audition_constructors+1 end
end
assert(audition_constructors==2 and contains(view("acid_program_panel"),program_audition) and
  contains(view("acid_grid_panel"),grid_audition) and
  rawequal(program_audition.notifier,grid_audition.notifier) and
  program_audition.active and grid_audition.active,
  "Program and Grid audition controls share one callback and belong to their own views")
fire("acid_editor_view",2)
assert(note_calls[#note_calls].kind=="off","view navigation releases audition")
fire("acid_grid_audition")
assert(note_calls[#note_calls].kind=="on" and note_calls[#note_calls].note==38,
  "Grid audition resolves the masked pitch to the same Renoise note")
fire("acid_editor_view",1)
assert(note_calls[#note_calls].kind=="off","returning to Program releases Grid audition")
fire("acid_editor_view",1)
fire("acid_audition")
fire("acid_program_pitch_page_2")
assert(note_calls[#note_calls].kind=="off","page navigation releases audition")
fire("acid_program_pitch_page_1")

fire("acid_program_key_09")
local before_audition=assert(seq.copy_source(current()))
local audition_writes,audition_saves=writes,saves
fire("acid_audition")
assert(note_calls[#note_calls].note==48,"PITCH audition resolves detached candidate")
fire("acid_editor_view",2)
assert(note_calls[#note_calls].kind=="off" and next(timers)==nil,"Grid switch releases candidate")
fire("acid_grid_audition")
assert(note_calls[#note_calls].kind=="on" and note_calls[#note_calls].note==38,
  "Grid auditions its accepted pitch during PITCH entry")
fire("acid_editor_view",1)
assert(note_calls[#note_calls].kind=="off" and next(timers)==nil,"Program switch releases accepted pitch")
fire("acid_audition")
assert(note_calls[#note_calls].note==48,"Program retains candidate audition after Grid")
assert(seq.same_source(before_audition,current()) and writes==audition_writes and saves==audition_saves)
cancel_stage("Cancel")
assert(note_calls[#note_calls].kind=="off","Cancel releases before its prompt")
fire("acid_audition")
assert(note_calls[#note_calls].note==38,"canonical audition resolves mask")
begin("time")
assert(not view("acid_audition").active and not view("acid_grid_audition").active,
  "TIME staging disables audition in both views")
local calls_before_time=#note_calls
fire("acid_audition")
fire("acid_grid_audition")
assert(#note_calls==calls_before_time,"TIME-stage notifier cannot trigger audition")
cancel_stage("Cancel")
local function releases(action,label)
  fire("acid_audition")
  assert(note_calls[#note_calls].kind=="on",label.." onset")
  local count=#note_calls
  action()
  assert(#note_calls==count+1 and note_calls[#note_calls].kind=="off",label.." releases once")
  assert(next(timers)==nil,label.." detaches timer")
end
for _,id in ipairs({"acid_program_select_pitch_01","acid_program_select_time_01",
    "acid_pitch_page_1","acid_time_page_1","acid_program_time_page_1"}) do
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
releases(function()cancel_stage("Cancel")end,"Cancel prompt")
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
