-- Native comparison must stay separate from both local effects and the reference.
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end
local source = { name = "ACID ARTICULATION PROBE", samples = { { modulation_set_index = 1 } },
  trigger_options = { monophonic = false, monophonic_glide = 0 }, phrases = { {} } }
local song = { instruments = { source } }
function song:describe_undo() end
function song:delete_instrument_at(index) table.remove(self.instruments, index) end
local fail_copy = false
function song:insert_instrument_at(index)
  local probe = {}
  function probe:copy_from(reference)
    if fail_copy then error("Injected copy failure") end
    for key, value in pairs(reference) do self[key] = clone(value) end
  end
  function probe:delete_phrase_at(slot) table.remove(self.phrases, slot) end
  function probe:insert_phrase_at(slot)
    local lines = {}
    local phrase = {}
    function phrase:line(line)
      if not lines[line] then lines[line] = { note_columns = { {} } } end
      return lines[line]
    end
    table.insert(self.phrases, slot, phrase)
    return phrase
  end
  table.insert(self.instruments, index, probe)
  return probe
end
renoise = { song = function() return song end, Song = { MAX_NUMBER_OF_INSTRUMENTS = 255 },
  InstrumentPhrase = { PLAY_PATTERN = 1, KEY_TRACKING_NONE = 1 },
  Instrument = { PHRASES_PLAY_SELECTIVE = 1 }, PatternLine = { NOTE_OFF = 120 } }
local function run() dofile("tests/acid/renoise_articulation_mono.lua") end
ACID_ARTICULATION_MONO_GLIDE = 256
assert(not pcall(run) and #song.instruments == 1, "Invalid glide mutated the song")
ACID_ARTICULATION_MONO_GLIDE = 32
fail_copy = true
assert(not pcall(run) and #song.instruments == 1, "Copy failure leaked a new instrument")
fail_copy = false
ACID_ARTICULATION_MONO_GLIDE = nil
setmetatable(_G, { __index = function(_, name) error("Undeclared global: " .. name) end })
run()
setmetatable(_G, nil)
local probe = song.instruments[2]
assert(probe ~= source and probe.trigger_options ~= source.trigger_options,
  "Comparison shares reference settings")
assert(not source.trigger_options.monophonic and source.trigger_options.monophonic_glide == 0,
  "Comparison changed the polyphonic reference")
assert(probe.trigger_options.monophonic and probe.trigger_options.monophonic_glide == 32)
assert(#probe.phrases == 2 and probe.phrases[1]:line(5).note_columns[1].note_value == 55
  and probe.phrases[2]:line(5).note_columns[1].note_value == 48,
  "Native comparison and same-pitch control are missing")
for _, phrase in ipairs(probe.phrases) do
  assert(phrase:line(11).note_columns[1].note_value == 120 and not phrase.looping)
  for line = 1, 16 do
    assert(phrase:line(line).note_columns[1].effect_number_string == nil,
      "Native comparison unexpectedly uses local glide")
  end
end
assert(not pcall(run) and #song.instruments == 2, "Duplicate comparison was inserted")
print("Native Mono/Glide comparison isolation and failure cleanup passed")
