dofile('tests/bootstrap.lua')('acid')
local scales = require('model.scales')

local parsed = assert(scales.parse('\239\187\191# custom scales\r\n[Modes]\r\nDorian = 0, 2, 3, 5, 7, 9, 10\r\n'))
assert(#parsed == 1 and parsed[1].name == 'Dorian' and parsed[1].category == 'Modes')
assert(table.concat(parsed[1].intervals, ',') == '0,2,3,5,7,9,10')
local malformed = {
  'No equals sign',
  ' = 0 2',
  'Missing root = 2 4 7',
  'Duplicate = 0 2 2',
  'Out of range = 0 12',
  'Not integer = 0 2.5',
  'Empty =',
  '#Hidden = 0 2',
  '[Bad]Category',
  '[Bad] = 0 2',
  '[A\tB]\nScale = 0 2',
  ('N'):rep(65) .. ' = 0 2'
}
for _, text in ipairs(malformed) do
  local entries, err = scales.parse(text)
  assert(entries == nil and err:find('line 1:', 1, true), text)
end
local late_error = scales.parse('Valid = 0 2 4\nBroken = 0 0')
assert(late_error == nil, 'parse must reject the entire input on any error')
assert(scales.parse(('x'):rep(scales.MAX_TEXT_BYTES + 1)) == nil, 'oversized input must be rejected')

local builtins = scales.builtin()
assert(#builtins >= 65 and #builtins <= 130, 'expected a broad deduplicated bundled library')
local scale_data = require('model.scale_data')
assert(#scale_data == #builtins, 'bundled data should store each membership once')
local found_major, seen_memberships = false, {}
local by_name = {}
for _, entry in ipairs(builtins) do
  local intervals = entry.intervals
  assert(intervals[1] == 0)
  for i = 2, #intervals do assert(intervals[i] > intervals[i - 1]) end
  local key = table.concat(intervals, ',')
  assert(not seen_memberships[key], 'duplicate membership: ' .. key)
  seen_memberships[key] = true
  by_name[entry.name] = entry
  if entry.name == 'Major' then found_major = true end
end
assert(found_major)
for i = 2, #builtins do assert(builtins[i - 1].name <= builtins[i].name) end
for _, name in ipairs({
  'Chromatic', 'Major', 'Dorian', 'Phrygian', 'Lydian', 'Mixolydian',
  'Natural Minor', 'Locrian', 'Harmonic Minor', 'Melodic Minor',
  'Major Pentatonic', 'Minor Pentatonic', 'Whole Tone',
  'Diminished (whole-half)', 'Diminished (half-whole)', 'Blues', 'Major Blues',
  'Lydian Dominant', 'Altered', 'Phrygian Dominant', 'Harmonic Major',
  'Double Harmonic Major', 'Hirajoshi', 'Pelog', 'Dominant Bebop',
  'Marwa Thaat', 'Poorvi Thaat', 'Todi Thaat', 'Minor Pentatonic b6'
}) do
  assert(by_name[name], 'missing common scale: ' .. name)
end
local function has_alias(entry, expected)
  for _, alias in ipairs(entry.aliases) do if alias == expected then return true end end
  return false
end
assert(has_alias(by_name['Natural Minor'], 'Aeolian'))
assert(by_name.Major.aliases[1] == 'Ionian')
assert(by_name['Major Pentatonic'].aliases[1] == 'Chinese Pentatonic')
assert(has_alias(by_name.Blues, 'Minor Blues'))
assert(has_alias(by_name['Double Harmonic Major'], 'Bhairav Thaat'))
assert(has_alias(by_name.Phrygian, 'Bhairavi Thaat'))
assert(has_alias(by_name.Mixolydian, 'Khamaj Thaat'))
assert(has_alias(by_name['Hungarian Minor'], 'Double Harmonic Minor'))
assert(has_alias(by_name['Major Hexatonic'], 'Scottish Hexatonic'))
assert(not has_alias(by_name['Major Hexatonic'], 'Scottish Pentatonic'))
assert(not has_alias(by_name.Blues, 'Minor Blues Pentatonic'))
assert(not by_name['Raga Malkauns'] and not by_name['Enigmatic Minor'])

local function signature(intervals)
  return table.concat(intervals, ',')
end
local function assert_mode_family(parent, names)
  local intervals = by_name[parent].intervals
  for degree, name in ipairs(names) do
    local root = intervals[degree]
    local rotated = {}
    for _, interval in ipairs(intervals) do rotated[#rotated + 1] = (interval - root) % 12 end
    table.sort(rotated)
    assert(by_name[name], 'missing mode ' .. name)
    assert(signature(by_name[name].intervals) == signature(rotated),
      name .. ' does not match mode ' .. degree .. ' of ' .. parent)
  end
end
assert_mode_family('Major', {'Major', 'Dorian', 'Phrygian', 'Lydian', 'Mixolydian', 'Natural Minor', 'Locrian'})
assert_mode_family('Melodic Minor', {'Melodic Minor', 'Dorian b2', 'Lydian Augmented',
  'Lydian Dominant', 'Mixolydian b6', 'Locrian #2', 'Altered'})
assert_mode_family('Harmonic Minor', {'Harmonic Minor', 'Locrian Natural 6', 'Ionian Augmented',
  'Dorian #4', 'Phrygian Dominant', 'Lydian #2', 'Ultralocrian'})
assert_mode_family('Harmonic Major', {'Harmonic Major', 'Dorian b5', 'Phrygian b4',
  'Lydian b3', 'Mixolydian b2', 'Lydian Augmented #2', 'Locrian bb7'})
assert_mode_family('Double Harmonic Major', {'Double Harmonic Major', 'Lydian #2 #6',
  'Ultraphrygian', 'Hungarian Minor', 'Oriental', 'Ionian #2 #5', 'Locrian bb3 bb7'})

local merged = scales.merge({
  {name='Major', category='Heptatonic', intervals={0,2,4,5,7,9,11}, aliases={}}
}, {
  {name='Ionian', category='Modes', intervals={0,2,4,5,7,9,11}, aliases={'Church mode I'}},
  {name='Custom minor', category='Custom', intervals={0,2,3,5,7,8,10}, aliases={}}
})
assert(#merged == 2 and merged[1].name == 'Major')
assert(merged[1].aliases[1] == 'Ionian' and merged[1].aliases[2] == 'Church mode I')
assert(merged[2].name == 'Custom minor')
local restored = scales.merge({}, assert(scales.parse(scales.encode(merged))))
assert(#restored == #merged)
for index, entry in ipairs(merged) do
  assert(restored[index].name == entry.name and restored[index].category == entry.category)
  assert(signature(restored[index].intervals) == signature(entry.intervals))
  assert(table.concat(restored[index].aliases, ',') == table.concat(entry.aliases, ','),
    'text roundtrip preserves alternate names')
end

local mask = scales.mask({intervals={0,2,4,5,7,9,11}}, 2)
local expected = {false, true, true, false, true, false, true, true, false, true, false, true}
for i = 1, 12 do assert(mask[i] == expected[i], 'mask mismatch at semitone ' .. (i - 1)) end
assert(not pcall(scales.mask, {intervals={0,12}}, 0))
assert(not pcall(scales.mask, {intervals={0}}, 12))
print('ACID scale library and custom text parsing passed')


