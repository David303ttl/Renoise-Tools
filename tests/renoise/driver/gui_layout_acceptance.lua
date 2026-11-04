local M = {}
local LAYOUT_SETTLE_SECONDS = 1.25
local LAYOUT_TIMEOUT_SECONDS = 10
local PROGRAM_VIEW = 1
local GRID_VIEW = 2
local OPERATION_PITCH = 1
local OPERATION_RANDOM_PITCH = 9
local EMPTY_HOLDER_WIDTH = 1
local EMPTY_HOLDER_HEIGHT = 1
local VISIBLE_HOLDER_MEMBER_COUNT = 1

local function read_size(view)
  if not view then return nil end
  local size = view.size
  assert(type(size) == "table", "production View.size did not return a size table")
  local width, height = size.width or size[1], size.height or size[2]
  assert(type(width) == "number" and type(height) == "number", "production View.size dimensions were not numeric")
  return {width=width,height=height}
end

function M.run(done, json)
  local original_builder, original_app = renoise.ViewBuilder, renoise.app
  local dialog, root
  local controls, callbacks = {}, {}
  local idle = renoise.tool().app_idle_observable
  local metrics = {states=json.array()}
  local settled, finishing, timer, cleanup_timer = false, false, nil, nil
  local finish_status, finish_reason
  local prompt_answer
  local suppress_callbacks = false
  local context_module, original_context_new, context, original_duplicate
  local song = renoise.song()
  local original_tool_data = song.tool_data
  local original_instrument = song.selected_instrument
  local original_phrase = song.selected_phrase

  local function complete()
    if settled then return end
    settled = true
    if cleanup_timer then pcall(function() idle:remove_notifier(cleanup_timer) end) end
    local ui_state = require("gui").get_ui_state()
    metrics.dialog_closed = ui_state.dialog_visible == false
    metrics.native_observers_detached = ui_state.native_observers_attached == false
    metrics.gui_idle_listener_detached = ui_state.idle_listener_attached == false
    metrics.document_unchanged = song.tool_data == original_tool_data and
      rawequal(song.selected_instrument,original_instrument) and rawequal(song.selected_phrase,original_phrase)
    if finish_status == "PASS" and (not metrics.dialog_closed or not metrics.native_observers_detached or
        not metrics.gui_idle_listener_detached or not metrics.document_unchanged) then
      finish_status, finish_reason = "FAIL", "dialog, GUI observers, idle listener or document state did not clean up"
    end
    done({status=finish_status,case="gui-layout",reason=finish_reason,metrics=metrics})
  end

  local function finish(status, reason)
    if settled or finishing then return end
    finishing, finish_status, finish_reason = true, status, reason
    if timer then pcall(function() idle:remove_notifier(timer) end); timer=nil end
    renoise.ViewBuilder, renoise.app = original_builder, original_app
    if context_module then context_module.new = original_context_new end
    if context and original_duplicate then context.request_duplicate = original_duplicate end
    if dialog then pcall(function() if dialog.visible then dialog:close() end end) end
    local started = os.clock()
    cleanup_timer = function()
      local ui_state = require("gui").get_ui_state()
      if ui_state.idle_listener_attached == false and ui_state.native_observers_attached == false then
        complete()
      elseif os.clock() - started > LAYOUT_TIMEOUT_SECONDS then
        finish_status, finish_reason = "FAIL", "GUI observer cleanup did not finish after dialog close"
        complete()
      end
    end
    idle:add_notifier(cleanup_timer)
  end

  local function capture_callback(id, callback)
    callbacks[id] = callback
    return function(...)
      if not settled and not finishing and not suppress_callbacks then return callback(...) end
    end
  end

  local function set_value(id, value)
    local control = assert(controls[id],"missing production control: "..id)
    suppress_callbacks = true
    control.value = value
    suppress_callbacks = false
    local callback = callbacks[id]
    if callback then callback(value) end
  end

  local function hold_state(name, next_action)
    local started = os.clock()
    timer = function()
      if settled then return end
      if os.clock() - started > LAYOUT_TIMEOUT_SECONDS then
        pcall(function() idle:remove_notifier(timer) end)
        timer = nil
        finish("FAIL","production GUI layout state did not settle within timeout")
        return
      end
      if os.clock() - started < LAYOUT_SETTLE_SECONDS then return end
      pcall(function() idle:remove_notifier(timer) end)
      timer = nil
      local ok, err = pcall(function()
      local program_panel_size=read_size(controls.acid_program_panel)
      local grid_panel_size=read_size(controls.acid_grid_panel)
      local entry = {
        name=name,
        captured_at=os.time(),
        dialog_visible=dialog and dialog.visible == true or false,
        root_size=read_size(root),
        program_panel_width=program_panel_size.width,
        grid_panel_width=grid_panel_size.width,
        program_view=controls.acid_editor_view and controls.acid_editor_view.value == PROGRAM_VIEW or false,
        entry_visible=controls.acid_program_stage_status and controls.acid_program_stage_status.visible == true or false,
        random_visible=controls.acid_random_parameters and controls.acid_random_parameters.visible == true or false,
        feedback_visible=controls.acid_feedback and controls.acid_feedback.visible == true or false,
        feedback_text=controls.acid_status and tostring(controls.acid_status.text) or "",
        feedback_size=read_size(controls.acid_feedback),
        entry_size=read_size(controls.acid_entry_holder),
        random_size=read_size(controls.acid_random_parameters),
        editor_view_members=controls.acid_editor_view_holder and #controls.acid_editor_view_holder.views or nil,
        entry_members=controls.acid_entry_holder and #controls.acid_entry_holder.views or nil,
        random_members=controls.acid_random_parameters and #controls.acid_random_parameters.views or nil,
        random_field_members=controls.acid_random_parameter_fields and #controls.acid_random_parameter_fields.views or nil,
        feedback_members=controls.acid_feedback and #controls.acid_feedback.views or nil,
        document_unchanged=song.tool_data == original_tool_data and
          rawequal(song.selected_instrument,original_instrument) and rawequal(song.selected_phrase,original_phrase),
      }
      metrics.states[#metrics.states+1] = entry
      if name == "program-compact" then
        metrics.program_compact_entry_members=entry.entry_members
        metrics.program_compact_entry_size=entry.entry_size
        metrics.compact_root_size=entry.root_size
      end
      if name == "program-entry-maximum" then
        metrics.expanded_entry_members=entry.entry_members
        metrics.expanded_entry_size=entry.entry_size
      end
      if name == "random-parameters-multiline-feedback" then metrics.feedback_root_size=entry.root_size end
      if name == "grid-compact" then
        metrics.grid_editor_members=entry.editor_view_members
        metrics.grid_compact_entry_members=entry.entry_members
        metrics.grid_compact_entry_size=entry.entry_size
      end
      if name == "random-parameters-multiline-feedback" or name == "program-entry-maximum" then
        metrics.expanded_random_members=entry.random_members
        metrics.expanded_random_size=entry.random_size
      end
      if name == "random-parameters-multiline-feedback" or name == "program-entry-maximum" then
        local _, line_count = entry.feedback_text:gsub("\n", "\n")
        metrics.feedback_line_count = line_count + 1
        metrics.feedback_multiline = line_count > 0 and entry.feedback_members > 0
      end
      if next_action then next_action() else finish("PASS") end
      end)
      if not ok then finish("FAIL",tostring(err)) end
    end
    idle:add_notifier(timer)
  end

  local function run()
    renoise.ViewBuilder = function(...)
      local builder = original_builder(...)
      return setmetatable({}, {__index=function(_, kind)
        local constructor = builder[kind]
        if type(constructor) ~= "function" then return constructor end
        return function(_, properties, ...)
          local id = type(properties) == "table" and properties.id
          if id and type(properties.notifier) == "function" then
            properties.notifier = capture_callback(id, properties.notifier)
          end
          local view = constructor(builder, properties, ...)
          if id then controls[id] = view end
          return view
        end
      end})
    end
    renoise.app = function(...)
      local app = original_app(...)
      return setmetatable({}, {__index=function(_, key)
        local member = app[key]
        if key == "show_custom_dialog" then
          return function(_, title, view, handler, settings)
            root = view
            metrics.opening_root_size = read_size(view)
            dialog = member(app,title,view,handler,settings)
            return dialog
          end
        elseif key == "show_prompt" then
          return function(_, ...)
            if prompt_answer then
              local answer = prompt_answer
              prompt_answer = nil
              return answer
            end
            return member(app,...)
          end
        end
        if type(member) == "function" then return function(_, ...) return member(app,...) end end
        return member
      end})
    end
    context_module = require("runtime.context")
    original_context_new = context_module.new
    context_module.new = function(...)
      context = original_context_new(...)
      original_duplicate = context.request_duplicate
      context.request_duplicate = function() return false,"injected duplicate rejection" end
      return context
    end
    local shown, show_error = pcall(function() require("gui").show() end)
    renoise.ViewBuilder = original_builder
    assert(shown,show_error)
    assert(dialog and dialog.visible,"production ACID dialog did not open")
    assert(controls.acid_editor_view and controls.acid_program_reenter_pitch and
      controls.acid_operation and controls.acid_random_parameters and controls.acid_status,
      "production layout controls were not captured")
    local _,draft_load_reason=require("runtime.draft_cache").get(song,song.selected_instrument,nil,
      context:draft_options())
    metrics.initial_draft_load_reason=draft_load_reason
    metrics.initial_instrument_name=song.selected_instrument.name
    hold_state("program-compact",function()
        set_value("acid_editor_view",GRID_VIEW)
      hold_state("grid-compact",function()
        set_value("acid_editor_view",PROGRAM_VIEW)
        set_value("acid_operation",OPERATION_RANDOM_PITCH)
        callbacks.acid_pattern_duplicate()
        context.request_duplicate = original_duplicate
        callbacks.acid_clipboard_paste()
        hold_state("random-parameters-multiline-feedback",function()
          prompt_answer="Proceed"
          callbacks.acid_program_reenter_pitch()
          hold_state("program-entry-maximum",function()
            set_value("acid_editor_view",GRID_VIEW)
            hold_state("grid-entry-maximum",function()
              set_value("acid_editor_view",PROGRAM_VIEW)
              prompt_answer="Cancel"
              callbacks.acid_program_discard()
              set_value("acid_operation",OPERATION_PITCH)
              hold_state("program-compact-after",function()
                local final=metrics.states[#metrics.states]
                local program_compact,grid_compact=metrics.states[1],metrics.states[2]
                local program_maximum, grid_maximum
                for _, state in ipairs(metrics.states) do
                  if state.name == "program-entry-maximum" then program_maximum=state end
                  if state.name == "grid-entry-maximum" then grid_maximum=state end
                end
                assert(metrics.program_compact_entry_members==VISIBLE_HOLDER_MEMBER_COUNT and
                  metrics.program_compact_entry_size and metrics.program_compact_entry_size.height>EMPTY_HOLDER_HEIGHT and
                  metrics.grid_compact_entry_members==0 and metrics.grid_compact_entry_size and
                  metrics.grid_compact_entry_size.width==EMPTY_HOLDER_WIDTH and
                  metrics.grid_compact_entry_size.height==EMPTY_HOLDER_HEIGHT and
                  metrics.expanded_entry_members==VISIBLE_HOLDER_MEMBER_COUNT and
                  final.entry_members==VISIBLE_HOLDER_MEMBER_COUNT and final.entry_size and
                  final.entry_size.width==metrics.program_compact_entry_size.width and
                  final.entry_size.height==metrics.program_compact_entry_size.height,
                  "production entry holder did not switch between Program controls and empty Grid state")
                assert(metrics.expanded_entry_size and
                  metrics.expanded_entry_size.width>EMPTY_HOLDER_WIDTH and
                  metrics.expanded_entry_size.height>EMPTY_HOLDER_HEIGHT and
                  metrics.expanded_entry_size.height>metrics.program_compact_entry_size.height,
                  "production Program entry holder did not expand from its launch controls")
                assert(metrics.expanded_random_members==VISIBLE_HOLDER_MEMBER_COUNT and metrics.expanded_random_size and
                  metrics.expanded_random_size.width>EMPTY_HOLDER_WIDTH and
                  metrics.expanded_random_size.height>EMPTY_HOLDER_HEIGHT and
                  final.random_members==0 and metrics.feedback_multiline,
                  "production parameter or multiline feedback holder did not expand and collapse")
                assert(final.random_size and final.random_size.width==EMPTY_HOLDER_WIDTH and
                  final.random_size.height==EMPTY_HOLDER_HEIGHT and
                  metrics.feedback_root_size and final.root_size and
                  metrics.feedback_root_size.width==final.root_size.width and
                  metrics.feedback_root_size.height-final.root_size.height==
                    metrics.expanded_random_size.height-EMPTY_HOLDER_HEIGHT,
                  "production random holder did not collapse or dialog root size did not return with feedback")
                assert(grid_maximum and not grid_maximum.program_view and grid_maximum.entry_visible and
                  grid_maximum.entry_size.width>EMPTY_HOLDER_WIDTH and
                  grid_maximum.entry_size.height>EMPTY_HOLDER_HEIGHT and
                  grid_maximum.random_members > 0 and grid_maximum.feedback_visible and
                  grid_maximum.feedback_text:find("\n",1,true),
                  "Grid maximum state did not retain staged entry, random parameters and multiline feedback")
                assert(program_maximum and program_maximum.program_view and program_maximum.entry_visible and
                  program_maximum.entry_size.width>EMPTY_HOLDER_WIDTH and
                  program_maximum.entry_size.height>metrics.program_compact_entry_size.height and
                  program_maximum.random_members > 0 and program_maximum.feedback_visible and
                  program_maximum.feedback_text:find("\n",1,true),
                  "Program maximum state did not retain staged entry, random parameters and multiline feedback")
                assert(final.document_unchanged,"layout probe changed song data or selection")
                local shared_panel_width=program_compact.program_panel_width
                assert(shared_panel_width and shared_panel_width>0,
                  "Program panel width was not measurable")
                for _,state in ipairs(metrics.states) do
                  assert(state.program_panel_width==shared_panel_width and
                    state.grid_panel_width==shared_panel_width,
                    "Editor panel widths diverged in layout state "..state.name)
                end
                assert(program_compact.root_size.width==grid_compact.root_size.width and
                  grid_compact.root_size.width==final.root_size.width,
                  "Program-to-Grid-to-Program changed the shared panel or root width")
                metrics.shared_panel_width=shared_panel_width
                metrics.root_width_stable_through_view_switch=true
                finish("PASS")
              end)
            end)
          end)
        end)
      end)
    end)
  end

  local ok, err = pcall(run)
  if not ok then finish("FAIL",tostring(err)) end
  return true
end

return M
