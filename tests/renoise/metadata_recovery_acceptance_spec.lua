local helper = dofile('tests/acid/runtime_phrase_fixture.lua')
local blank_phrase = dofile('tests/acid/complete_phrase_fixture.lua')
local ownership = require('renoise.phrase_ownership')
local integrity = require('runtime.integrity')
local original_integrity_new = integrity.new

local function fixture()
  renoise.song = nil
  local song, instrument = helper.fixture()
  instrument.phrases[2] = nil
  song.selected_instrument, song.selected_instrument_index = instrument, 1
  local function add_phrases(owner)
    function owner:insert_phrase_at(index)
      local phrase = blank_phrase(helper.limits)
      table.insert(self.phrases, index, phrase)
      return phrase
    end
  end
  add_phrases(instrument)
  function song:insert_instrument_at(index)
    local owner = helper.instrument({})
    add_phrases(owner)
    table.insert(self.instruments, index, owner)
    return owner
  end
  local idle = {notifiers = {}}
  function idle:add_notifier(callback) self.notifiers[callback] = true end
  function idle:has_notifier(callback) return self.notifiers[callback] == true end
  function idle:remove_notifier(callback) assert(self.notifiers[callback]); self.notifiers[callback] = nil end
  local key_handler, dialog
  renoise.song = function() return song end
  renoise.tool = function() return {app_idle_observable = idle} end
  renoise.ViewBuilder = setmetatable({DEFAULT_DIALOG_MARGIN = 4}, {__call = function()
    return {column = function(_, value) return value end, text = function(_, value) return value end,
      button = function(_, value) return value end}
  end})
  renoise.app = function() return {show_custom_dialog = function(_, _, _, handler)
    key_handler = handler
    dialog = {visible = true, close = function(self) self.visible = false end}
    return dialog
  end} end
  local saved = 0
  local helpers = {
    save = function(_, name) saved = saved + 1; return {fixture = name} end,
    baseline = function(current)
      return current.tool_data .. ':' .. current.instruments[2].phrases[1]:line(8):note_column(1).note_value
    end,
  }
  return song, idle, helpers, function() key_handler(dialog, {name = 'enter', state = 'pressed'}) end,
    function() return saved end
end

-- Exercise the actual acceptance module with production runtime/store logic.
-- The injected old whole-song receipt proves that the native scenario can fail.
for _, regress in ipairs({false, true}) do
  local song, idle, helpers, enter, saved = fixture()
  local runner = dofile('tests/renoise/driver/metadata_recovery_acceptance.lua')
  local original_song, original_current, original_capture = renoise.song, ownership.is_current, ownership.capture_recovery
  if regress then
    integrity.new = function(...)
      local owner = original_integrity_new(...)
      owner.capture_metadata = owner.capture_mutation
      return owner
    end
  end
  local result
  assert(runner.run('metadata-recovery-prepare', function(value) result = value end, helpers))
  assert(result.status == 'PASS' and result.action_ready and next(idle.notifiers))
  enter()
  assert(rawequal(renoise.song, original_song) and ownership.is_current == original_current
    and ownership.capture_recovery == original_capture, 'acceptance leaked fault injection')
  assert(runner.run('metadata-recovery', function(value) result = value end, helpers))
  integrity.new = original_integrity_new
  assert(next(idle.notifiers) == nil, 'acceptance leaked idle notifier')
  if regress then
    assert(result.status == 'FAIL' and saved() == 0, 'native scenario accepted whole-song label recovery: status=' .. tostring(result.status) .. ' saved=' .. tostring(saved()) .. ' reason=' .. tostring(result.reason))
  else
    assert(result.status == 'PASS' and saved() == 1, result.reason)
    assert(result.checks.owned_rename_without_render and not result.checks.new_rename_without_render)
    assert(result.checks.owned_uncertain_write_blocked and not result.checks.new_uncertain_write_blocked)
    assert(result.checks.zero_generation_and_recovery_reads)
    local cold = dofile('tests/renoise/driver/metadata_recovery_acceptance.lua')
    assert(cold.run('metadata-recovery-cold', function(value) result = value end, helpers))
    assert(result.status == 'PASS' and result.read_only_restore, result.reason)
    song.instruments[2].phrases[1]:line(8):note_column(1).note_value = 55
    cold.run('metadata-recovery-cold', function(value) result = value end, helpers)
    assert(result.status == 'FAIL', 'cold acceptance ignored a lost unrelated native edit')
  end
end
print('Metadata recovery acceptance action, failure detection, cold readback and cleanup passed')
