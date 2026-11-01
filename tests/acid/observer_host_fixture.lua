-- API-shaped native observer fixtures.
local M={}

function M.observable()
  local handlers={}
  local value={}
  function value:add_notifier(handler) handlers[handler]=true end
  function value:remove_notifier(handler) handlers[handler]=nil end
  function value:fire(...)
    local pending={}
    for handler in pairs(handlers) do pending[#pending+1]=handler end
    for _,handler in ipairs(pending) do
      if handlers[handler] then handler(...) end
    end
  end
  function value:listener_count()
    local count=0
    for _ in pairs(handlers) do count=count+1 end
    return count
  end
  return value
end

local function ensure(object,key,observable)
  if object[key]==nil then object[key]=observable() end
end

local PHRASE_PROPERTIES={
  "name","playback_mode","is_empty","number_of_lines","visible_note_columns",
  "visible_effect_columns","key_tracking","base_note","looping","loop_start",
  "loop_end","autoseek","lpb","shuffle","instrument_column_visible",
  "volume_column_visible","panning_column_visible","delay_column_visible",
  "sample_effects_column_visible",
}
local SCRIPT_PROPERTIES={"editor_visible","parameters","paragraphs",
  "paragraphs_assignment","pending_changes","committed"}
local MAPPING_PROPERTIES={"key_tracking","base_note","note_range","looping","loop_start","loop_end"}
local function attach_phrase(phrase,observable)
  for _,property in ipairs(PHRASE_PROPERTIES) do ensure(phrase,property.."_observable",observable) end
  phrase._column_name_observables=phrase._column_name_observables or {}
  phrase._column_mute_observables=phrase._column_mute_observables or {}
  if type(phrase.column_name_observable)~="function" then
    function phrase:column_name_observable(column)
      ensure(self._column_name_observables,column,observable)
      return self._column_name_observables[column]
    end
  end
  if type(phrase.column_is_muted_observable)~="function" then
    function phrase:column_is_muted_observable(column)
      ensure(self._column_mute_observables,column,observable)
      return self._column_mute_observables[column]
    end
  end
  if type(phrase.add_line_notifier)~="function" or type(phrase.remove_line_notifier)~="function" then
    local lines={}
    function phrase:add_line_notifier(handler) lines[handler]=true end
    function phrase:remove_line_notifier(handler) lines[handler]=nil end
    function phrase:fire_line_notifier(...)
      local pending={}
      for handler in pairs(lines) do pending[#pending+1]=handler end
      for _,handler in ipairs(pending) do if lines[handler] then handler(...) end end
    end
  end
  if phrase.mapping then
    for _,property in ipairs(MAPPING_PROPERTIES) do ensure(phrase.mapping,property.."_observable",observable) end
  end
  phrase.script=phrase.script or {}
  for _,property in ipairs(SCRIPT_PROPERTIES) do ensure(phrase.script,property.."_observable",observable) end
end

function M.attach(song,observable)
  observable=observable or M.observable
  ensure(song,"instruments_observable",observable)
  ensure(song,"selected_instrument_observable",observable)
  ensure(song,"selected_phrase_observable",observable)
  for _,instrument in ipairs(song.instruments or {}) do
    ensure(instrument,"name_observable",observable)
    ensure(instrument,"phrases_observable",observable)
    ensure(instrument,"phrase_mappings_observable",observable)
    ensure(instrument,"phrase_playback_mode_observable",observable)
    ensure(instrument,"phrase_program_observable",observable)
    for _,phrase in ipairs(instrument.phrases or {}) do attach_phrase(phrase,observable) end
  end
  return song
end

return M
