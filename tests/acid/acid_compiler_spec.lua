dofile('tests/bootstrap.lua')('acid')
local sequencer = require('model.sequencer')
local compiler = require('model.cycle_interpreter')
local pitch = dofile('tests/acid/pitch_fixture.lua')

local function pattern(time, pitches)
  local p = sequencer.new_pattern(#time)
  p.pitch_length = math.max(#pitches, 1)
  for step,command in ipairs(time) do p.time_events[step] = command end
  for i, pitch in ipairs(pitches) do p.pitch_events[i] = pitch end
  return p
end

local p = pattern({'N', 'T', 'N', 'R', 'N'}, {
  pitch(36,false,true), pitch(39,true,false), pitch(43)
})
local events = assert(compiler.compile_cycle(p))
assert(events.note_count == 3)
assert(events.steps[1].note == 36 and events.steps[1].transition == 'attack')
assert(events.steps[2].kind == 'tie' and events.steps[2].holds)
assert(events.steps[3].note == 39 and events.steps[3].transition == 'slide')
assert(events.steps[3].from_note == 36 and events.steps[3].accent)
assert(events.steps[4].kind == 'rest' and events.steps[4].releases)
assert(events.steps[5].note == 43 and events.steps[5].transition == 'attack')
assert(assert(compiler.plan_loop(p)).steady.steps[1].transition == 'retrigger')

local repeated = assert(compiler.compile_cycle(pattern({'N', 'R', 'N', 'T', 'N'}, {
  pitch(36), pitch(40)
})))
assert(repeated.steps[3].note == 40)
assert(repeated.steps[4].holds and repeated.steps[4].note == 40)
assert(repeated.steps[5].note == 36 and repeated.steps[5].transition == 'retrigger')

local same = assert(compiler.compile_cycle(pattern({'N', 'N'}, {
  pitch(36,false,true), pitch(36)
})))
assert(same.steps[2].transition == 'slide' and same.steps[2].from_note == 36)

local wrap = assert(compiler.plan_loop(pattern({'N', 'T', 'N'}, {
  pitch(36), pitch(40,false,true)
})))
assert(wrap.steady.steps[1].transition == 'slide')
assert(wrap.cold.steps[3].voice.note == 40)

local broken = assert(compiler.plan_loop(pattern({'N', 'N', 'R'}, {
  pitch(36), pitch(40,false,true)
})))
assert(broken.steady.steps[1].transition == 'attack')
assert(not compiler.compile_cycle(pattern({'T', 'N'}, {{note=36}})))

local empty = assert(compiler.compile_cycle(pattern({'R', 'R'}, {})))
assert(empty.note_count == 0)
local out_of_range=pitch(60)
out_of_range.note=120
assert(not compiler.compile_cycle(pattern({'N', 'R'}, {out_of_range})))
assert(not compiler.compile_cycle({length=3,pitch_events={{note=36}},time_events={'N', 'T'}}))

print('ACID semantic compiler checks passed')
