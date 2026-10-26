dofile('tests/bootstrap.lua')('acid')
-- Run from repository root: lua tests/acid/acid_pattrns_spec.lua
local emitter = require('writers.pattrns_writer')

local function compile_script(source)
  -- Mock the pattrns "pattern" constructor; validate emitted Lua source
  -- and exercise the actual event generator with realistic pulse contexts.
  local previous = _G.pattern
  _G.pattern = function(opts) return opts end
  local factory, err = (loadstring or load)(source)
  assert(factory, err)
  local ok, result = pcall(factory)
  _G.pattern = previous
  assert(ok, result)
  return result
end

local sample = {
  length = 8,
  steps = {
    {kind='note',step=1,note=36,accent=false,slide=true,transition='attack'},
    {kind='tie',step=2,holds=true},
    {kind='note',step=3,note=39,accent=true,slide=false,transition='slide'},
    {kind='rest',step=4,releases=true},
    {kind='note',step=5,note=43,accent=false,slide=false,transition='attack'},
    {kind='rest',step=6,releases=true},
    {kind='rest',step=7,releases=false},
    {kind='tie',step=8,holds=false}
  }
}
local source, meta = assert(emitter.emit(sample))
assert(source == assert(emitter.emit(sample)))
assert(meta.steps == 8 and meta.note_count == 3 and meta.off_count == 2)
assert(meta.slide_intentions == 2 and meta.requires_articulation)
assert(not source:find('Gxx', 1, true))
local options = compile_script(source)
assert(options.unit == '1/16' and options.repeats == false)
assert(#options.pulse == 8)
for i=1,8 do assert(options.pulse[i] == 1) end
local expected = {
  {key=36, volume=0.7}, nil, {key=39,volume=1.0}, 'off',
  {key=43,volume=0.7}, 'off', nil, nil
}
for i=1,8 do
  local value = options.event({pulse_step=i,step=i})
  if expected[i] == nil then assert(value == nil)
  elseif type(expected[i]) == 'table' then
    assert(value.key == expected[i].key and value.volume == expected[i].volume)
  else assert(value == expected[i]) end
end
assert(options.event({pulse_step=9}) == nil)
local custom = assert(emitter.emit(sample, {normal_volume=0.4,accent_volume=0.9}))
assert(custom:find('volume = 0.400000', 1, true))
assert(custom:find('volume = 0.900000', 1, true))
assert(not emitter.emit(sample, {unit='1/8'}))
assert(not emitter.emit(sample, {normal_volume=1.1}))
assert(not emitter.emit({length=2, steps={{step=1,kind='note',note=36}}}))
assert(not emitter.emit({length=1, steps={{step=1,kind='rest'}}}))
assert(not emitter.emit({length=1, steps={{step=1,kind='invalid'}}}))

-- End-to-end path via sequencer/compiler, with a REST not consuming a pitch.
local p = {
  length=5,
  pitch_events={{note=36,slide=true},{note=40,accent=true},{note=43}},
  time_events={'N','T','N','R','N'}
}
local generated, result = assert(emitter.generate(p))
local actual = compile_script(generated)
assert(result.note_count == 3 and result.off_count == 1)
assert(actual.event({pulse_step=1}).key == 36)
assert(actual.event({pulse_step=2}) == nil)
assert(actual.event({pulse_step=3}).key == 40)
assert(actual.event({pulse_step=4}) == 'off')
assert(actual.event({pulse_step=5}).key == 43)
assert(not emitter.generate({length=3,pitch_events={{note=36}},time_events={'N'}}))
print('ACID pattrns script emitter checks passed')
