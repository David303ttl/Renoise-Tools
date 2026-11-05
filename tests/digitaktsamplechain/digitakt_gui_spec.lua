dofile('tests/bootstrap.lua')('digitaktsamplechain')

local chain_options = require('chain_options')
local function equal(actual, expected, message)
  assert(actual == expected, (message or 'values differ') ..
    ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function truthy(value, message)
  assert(value, message or 'expected a truthy value')
end

local function contains(text, fragment)
  return type(text) == 'string' and text:find(fragment, 1, true) ~= nil
end

local function setup(options)
  package.loaded['gui'] = nil
  local state = {
    views = {}, feedback = {}, dialogs = {}, starts = {}, jobs = {},
    prompts = {}, errors = {}, warnings = {},
  }
  state.song = { selected_instrument = { samples = { { sample_buffer = {} } } } }

  local function builder()
    local instance = {}
    local function make(kind, properties)
      properties = properties or {}
      properties.kind = kind
      if properties.active == nil then properties.active = true end
      state.views[#state.views + 1] = properties
      if kind == 'text' and properties.text == '' then
        state.feedback[#state.feedback + 1] = properties
      end
      return properties
    end
    for _, kind in ipairs({ 'text', 'popup', 'checkbox', 'button', 'column',
      'horizontal_aligner', 'space' }) do
      instance[kind] = function(_, properties) return make(kind, properties) end
    end
    return instance
  end

  state.app = {
    show_warning = function(_, message) state.warnings[#state.warnings + 1] = message end,
    show_error = function(_, message) state.errors[#state.errors + 1] = message end,
    prompt_for_filename_to_write = function(_, extension, title)
      state.prompts[#state.prompts + 1] = { extension = extension, title = title }
      if options.prompt then return table.remove(options.prompt, 1) end
      return ''
    end,
    show_custom_dialog = function(_, title, content)
      local dialog = {
        title = title,
        content = content,
        visible = true,
        show_count = 0,
        show = function(self) self.visible = true; self.show_count = self.show_count + 1 end,
        close = function(self) self.visible = false end,
      }
      state.dialogs[#state.dialogs + 1] = dialog
      return dialog
    end,
  }
  renoise = {
    song = function()
      if options.no_song then return nil end
      return state.song
    end,
    app = function() return state.app end,
    ViewBuilder = builder,
  }
  package.loaded['export_runner'] = {
    start = function(instrument, export_options, path, callbacks)
      local call = { instrument = instrument, options = export_options,
        path = path, callbacks = callbacks }
      state.starts[#state.starts + 1] = call
      if options.start_error then return nil, options.start_error end
      local job = { canceled = false, cancel_count = 0 }
      function job:cancel()
        self.canceled = true
        self.cancel_count = self.cancel_count + 1
        if self.on_cancel then self.on_cancel('Canceled by test job.') end
      end
      job.on_cancel = function(message) callbacks.on_cancel(message) end
      call.job = job
      state.jobs[#state.jobs + 1] = job
      return job
    end,
  }
  return state, require('gui')
end

local function find_view(state, kind, predicate)
  for i = #state.views, 1, -1 do
    local view = state.views[i]
    if view.kind == kind and (not predicate or predicate(view)) then return view end
  end
  error('view not found: ' .. kind)
end

local function find_popup(state, labels)
  for _, view in ipairs(state.views) do
    if view.kind == 'popup' and #view.items == #labels then
      local matches = true
      for i, label in ipairs(labels) do
        if view.items[i] ~= label then matches = false end
      end
      if matches then return view end
    end
  end
  error('popup not found')
end

local function feedback_text(state, index)
  return assert(state.feedback[index], 'feedback view not found: ' .. tostring(index))
end

local function click_export(state)
  return find_view(state, 'button', function(v) return v.text == 'Export Chain' end).notifier()
end

local function click_cancel(state)
  return find_view(state, 'button', function(v) return v.text == 'Cancel Export' end).notifier()
end

local function fresh_dialog()
  local state, gui = setup({})
  gui.show()
  return state, gui
end

-- Popup contents/defaults, mapping and dependent controls.
do
  local state, gui = fresh_dialog()
  gui.show()
  equal(#state.dialogs, 1)
  equal(state.dialogs[1].show_count, 1)
  local mode = find_popup(state, chain_options.export_mode_labels())
  local slots = find_popup(state, chain_options.slot_count_labels())
  local mono = find_popup(state, chain_options.mono_mode_labels())
  equal(mode.value, 1)
  equal(slots.value, 1)
  equal(mono.value, 1)
  equal(mode.items[1], 'Spaced (Digitakt Grid)')
  equal(slots.items[1], 'Auto')
  equal(mono.items[1], 'Average Channels')
  truthy(slots.active, 'slot selection should be enabled in spaced mode')
  local boxes = {}
  for _, view in ipairs(state.views) do
    if view.kind == 'checkbox' then boxes[#boxes + 1] = view end
  end
  equal(#boxes, 3)
  equal(boxes[1].value, false)
  equal(boxes[2].value, false)
  equal(boxes[3].value, false)
  mode.notifier(2)
  equal(slots.active, false)
  equal(boxes[3].active, false)
  mode.notifier(1)
  equal(slots.active, true)
  equal(chain_options.export_mode(2), 'chain')
  equal(chain_options.slot_count(1), nil)
  equal(chain_options.slot_count(4), 16)
  equal(chain_options.mono_mode(3), 'right')
end

-- All selected settings are forwarded, with prompt contract and labels.
do
  local state, gui = setup({ prompt = { 'C:/tmp/chain.wav' } })
  gui.show()
  local mode = find_popup(state, chain_options.export_mode_labels())
  local slots = find_popup(state, chain_options.slot_count_labels())
  local mono = find_popup(state, chain_options.mono_mode_labels())
  mode.notifier(2)
  slots.notifier(4)
  mono.notifier(3)
  local boxes = {}
  for _, view in ipairs(state.views) do if view.kind == 'checkbox' then boxes[#boxes + 1] = view end end
  boxes[1].notifier(true)
  boxes[2].notifier(true)
  boxes[3].notifier(true)
  click_export(state)
  equal(#state.starts, 1)
  local call = state.starts[1]
  equal(call.instrument, state.song.selected_instrument)
  equal(call.path, 'C:/tmp/chain.wav')
  equal(call.options.mode, 'chain')
  equal(call.options.slot_count, 16)
  equal(call.options.mono, 'right')
  equal(call.options.fade, true)
  equal(call.options.dither, true)
  equal(call.options.zero_pad, true)
  equal(state.prompts[1].extension, 'wav')
  equal(state.prompts[1].title, 'Export Digitakt Chain')
  local duration = feedback_text(state, 2)
  call.callbacks.on_finish({ slot_count = 16, frames = 1234, sample_rate = 48000,
    mode = 'chain', slot_sec = 0.125, total_sec = 2.0 })
  truthy(contains(duration.text, 'Mean Sample: 0.125 sec'))
  truthy(contains(duration.text, 'Total: 2.000 sec'))
  call.callbacks.on_finish({ slot_count = 8, frames = 567, sample_rate = 48000,
    mode = 'spaced', slot_sec = 0.250, total_sec = 2.0 })
  truthy(contains(duration.text, 'Slot: 0.250 sec'))
end

-- Empty path cancels without starting; failed starts clear old durations.
do
  local state, gui = setup({ prompt = { '' } })
  gui.show()
  click_export(state)
  equal(#state.prompts, 1)
  equal(#state.starts, 0)
  local failed_state, failed_gui = setup({ prompt = { 'C:/tmp/fail.wav' }, start_error = 'runner unavailable' })
  failed_gui.show()
  local failed_duration = feedback_text(failed_state, 2)
  failed_duration.text = 'stale duration'
  click_export(failed_state)
  equal(failed_duration.text, '')
  equal(failed_state.errors[1], 'runner unavailable')
  truthy(contains(feedback_text(failed_state, 1).text, 'failed'))
end

-- Running state, progress, cancellation and duplicate-start guard.
do
  local state, gui = setup({ prompt = { 'C:/tmp/run.wav' } })
  gui.show()
  click_export(state)
  local call = state.starts[1]
  equal(find_view(state, 'button', function(v) return v.text == 'Export Chain' end).active, false)
  equal(find_view(state, 'button', function(v) return v.text == 'Cancel Export' end).active, true)
  equal(find_popup(state, chain_options.export_mode_labels()).active, false)
  local status = feedback_text(state, 1)
  call.callbacks.on_progress('Rendering slot 3 of 16...')
  equal(status.text, 'Rendering slot 3 of 16...')
  click_export(state)
  equal(#state.starts, 1)
  click_cancel(state)
  equal(state.jobs[1].canceled, true)
  equal(find_view(state, 'button', function(v) return v.text == 'Export Chain' end).active, true)
  equal(find_view(state, 'button', function(v) return v.text == 'Cancel Export' end).active, false)
  equal(status.text, 'Canceled by test job.')
end

-- Duration is reset at the next attempt; no-song warning avoids a prompt.
do
  local state, gui = setup({ prompt = { 'C:/tmp/first.wav', '' } })
  gui.show()
  click_export(state)
  state.starts[1].callbacks.on_finish({ slot_count = 4, frames = 400, sample_rate = 48000,
    mode = 'spaced', slot_sec = 1, total_sec = 4 })
  local duration = feedback_text(state, 2)
  truthy(contains(duration.text, 'Slot:'))
  click_export(state)
  equal(duration.text, '')
  equal(#state.starts, 1)
  local no_song, no_song_gui = setup({ no_song = true })
  no_song_gui.show()
  click_export(no_song)
  equal(no_song.warnings[1], 'Open a Renoise song first.')
  equal(#no_song.prompts, 0)
  equal(#no_song.starts, 0)
end

-- Close while running cancels on progress; reopened views reject stale callbacks.
do
  local state, gui = setup({ prompt = { 'C:/tmp/old.wav', 'C:/tmp/new.wav' } })
  gui.show()
  click_export(state)
  local old_call = state.starts[1]
  local old_dialog = state.dialogs[1]
  old_dialog:close()
  old_call.callbacks.on_progress('late progress')
  equal(state.jobs[1].canceled, true)
  gui.show()
  equal(#state.dialogs, 2)
  truthy(state.dialogs[2] ~= old_dialog)
  local new_status = feedback_text(state, 3)
  old_call.callbacks.on_finish({ slot_count = 4, frames = 400, sample_rate = 48000,
    mode = 'spaced', slot_sec = 1, total_sec = 4 })
  equal(new_status.text, '')
  click_export(state)
  equal(new_status.text, 'Exporting...')
  equal(state.jobs[1].canceled, true)
  equal(#state.starts, 2)
end

-- Runtime errors use error presentation, and entry registration invokes gui.show.
do
  local state, gui = setup({ prompt = { 'C:/tmp/cleanup.wav' } })
  gui.show()
  click_export(state)
  state.dialogs[1]:close()
  local original_print, logged = print
  print = function(message) logged = message end
  local ok, err = pcall(state.starts[1].callbacks.on_cancel, 'Could not remove temporary file')
  print = original_print
  assert(ok, err)
  truthy(contains(logged, 'Could not remove temporary file'), 'closed-dialog cleanup errors must stay visible in logs')
end

do
  local state, gui = setup({ prompt = { 'C:/tmp/error.wav' } })
  gui.show()
  click_export(state)
  state.starts[1].callbacks.on_error('bad sample data')
  equal(state.errors[1], 'bad sample data')
  local status = feedback_text(state, 1)
  equal(status.text, 'Export failed.')
end

do
  local invoked = 0
  package.loaded['gui'] = { show = function() invoked = invoked + 1 end }
  package.loaded['main'] = nil
  local entries = {}
  renoise = { tool = function()
    return { add_menu_entry = function(_, entry) entries[#entries + 1] = entry end }
  end }
  require('main')
  equal(#entries, 1)
  equal(entries[1].name, 'Sample Editor:Export Digitakt Sample Chain')
  entries[1].invoke()
  equal(invoked, 1)
  package.loaded['main'] = nil
end

print('digitakt_gui_spec: all tests passed')
