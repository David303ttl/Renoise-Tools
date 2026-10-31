local file = assert(io.open("tests/renoise/driver/acceptance_cases.lua", "rb"))
local contents = file:read("*a")
file:close()
local prefix = assert(contents:match("^(.-)local function save_independent_fixture"))
local baseline = assert(loadstring(prefix .. "\nreturn persisted_baseline"))()

package.loaded["renoise.phrase_ownership"] = {
  id = function(phrase) return phrase.id end,
  snapshot = function(phrase) return phrase.snapshot end,
}
local source = { pitch_events = { { note = 48 }, { note = 59, active = false } } }
local policy, pb = "preserve", 12
package.loaded["renoise.pattern_store"] = {
  read_entry = function() return source, policy, pb end,
}
local phrase = { id = 7, snapshot = { name = "ACID identity/seal", lines = {
  { notes = { { note = 48 }, { note = 121 } } },
  { notes = { { note = 121 }, { note = 121 } } },
} } }
local sentinel = { snapshot = { name = "Foreign sentinel", lines = {} } }
local song = { tool_data = "source\n\000\255", instruments = {
  { name = "Original", phrases = { phrase, sentinel } },
} }
local expected = baseline(song)
assert(expected == baseline(song), "baseline must be deterministic")
local function detects(change, restore, message)
  change()
  assert(expected ~= baseline(song), message)
  restore()
  assert(expected == baseline(song), "restored fixture differs")
end
detects(function() phrase.id = 8 end, function() phrase.id = 7 end, "identity drift escaped")
detects(function() source.pitch_events[2] = nil end,
  function() source.pitch_events[2] = { active = false, note = 59 } end,
  "lost inactive source memory escaped")
detects(function() policy = "replace" end, function() policy = "preserve" end, "policy drift escaped")
detects(function() pb = 2 end, function() pb = 12 end, "PB drift escaped")
detects(function() phrase.snapshot.name = "other seal" end,
  function() phrase.snapshot.name = "ACID identity/seal" end, "seal drift escaped")
detects(function() sentinel.snapshot.name = "changed" end,
  function() sentinel.snapshot.name = "Foreign sentinel" end, "sentinel drift escaped")
detects(function() phrase.snapshot.lines[2].notes[2].note = 60 end,
  function() phrase.snapshot.lines[2].notes[2].note = 121 end, "inactive cell drift escaped")
detects(function() song.tool_data = "source\n\000\254" end,
  function() song.tool_data = "source\n\000\255" end, "raw byte drift escaped")
local saved = source.pitch_events[2].note
source.pitch_events[2].note = 1
local precise = baseline(song)
source.pitch_events[2].note = 1 + 2^-50
assert(precise ~= baseline(song), "numeric precision drift escaped")
source.pitch_events[2].note = saved
song.tool_data = nil
local absent = baseline(song)
song.tool_data = ""
assert(absent ~= baseline(song), "absent and empty persisted values were conflated")
print("Persisted native baselines detect identity, inactive source, settings, snapshot and byte drift")
