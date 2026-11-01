dofile('tests/bootstrap.lua')('acid')
local seq = require('model.sequencer')
local interpreter = require('model.cycle_interpreter')
local pitch = dofile('tests/acid/pitch_fixture.lua')
local json = dofile('tests/acid/fixture_json.lua')
local oracle = json.read('tests/acid/fixtures/loop_cases.json')

local function equal(actual, expected, message)
  assert(actual == expected, message .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function source(case)
  local p = seq.new_pattern(case.length)
  p.pitch_length = case.pitch_length
  for step,command in ipairs(case.time) do p.time_events[step]=command end
  for i, source_pitch in ipairs(case.pitches) do
    p.pitch_events[i]=pitch(source_pitch.note,source_pitch.accent,source_pitch.slide)
  end
  return p
end

local function check_case(case)
  local p = source(case)
  local plans, exit = assert(interpreter.compile_cycles(p, 3))
  local state
  for cycle, plan in ipairs(plans) do
    local single, next_state = assert(interpreter.compile_cycle(p, state))
    local expected = case.expected[cycle]
    local notes, ties, rests = 0, 0, 0
    equal(plan.entry_kind, cycle == 1 and 'cold' or 'repeat', case.id)
    for step, event in ipairs(plan.steps) do
      local context = case.id .. ' cycle ' .. cycle .. ' step ' .. step
      equal(event.absolute_step, (cycle-1)*p.length+step, context)
      equal(single.steps[step].kind, event.kind, context)
      equal(single.steps[step].pitch_index, event.pitch_index, context)
      equal(single.steps[step].transition, event.transition, context)
      if event.kind == 'note' then
        notes = notes + 1
        equal(event.pitch_index, expected.note_pitch_indices[notes], context)
        equal(event.note, expected.note_values[notes], context)
        equal(event.transition, expected.note_transitions[notes], context)
        equal(event.connected, event.transition == 'slide', context)
      elseif event.kind == 'tie' then
        ties = ties + 1
        local expected_note = expected.tie_notes[ties]
        if expected_note == json.null then expected_note = nil end
        equal(event.note, expected_note, context)
        equal(event.holds, expected_note ~= nil, context)
      else
        rests = rests + 1
        equal(event.releases, expected.rest_releases[rests], context)
      end
    end
    equal(notes, #expected.note_values, case.id)
    equal(ties, #expected.tie_notes, case.id)
    equal(rests, #expected.rest_releases, case.id)
    equal(next_state.next_pitch, expected.exit_next_pitch, case.id)
    if expected.exit_voice == json.null then
      equal(next_state.voice, nil, case.id)
    else
      for _, key in ipairs({'note','pitch_index','slide'}) do
        equal(next_state.voice[key], expected.exit_voice[key], case.id .. ' exit ' .. key)
      end
    end
    state = next_state
  end
  equal(exit.next_pitch, state.next_pitch, case.id)
  equal(exit.voice and exit.voice.note, state.voice and state.voice.note, case.id)
end

for _, case in ipairs(oracle.cases) do
  if case.length<=seq.MAX_STEPS and case.pitch_length<=seq.MAX_STEPS then
    check_case(case)
    local loop = assert(interpreter.plan_loop(source(case)))
    equal(loop.cold.cycle, 1, case.id .. ' cold cycle')
    equal(loop.steady.cycle, 2, case.id .. ' steady cycle')
    equal(loop.verification.cycle, 3, case.id .. ' verification cycle')
  end
end

for _, entry in ipairs(oracle.entry_cases) do
  if entry.operation == 'enter_time' then
    local case = {length=entry.length, pitch_length=entry.pitch_length,
      pitches=entry.pitches, time={}}
    for step, command in ipairs(entry.input_time) do
      case.time[step] = assert(seq.normalize_time_entry(step, command))
      equal(case.time[step], entry.expected_time[step], entry.id)
    end
    local p = source(case)
    local plans = assert(interpreter.compile_cycles(p, 3))
    for cycle, plan in ipairs(plans) do
      local n = 0
      for _, event in ipairs(plan.steps) do
        if event.kind == 'note' then
          n = n + 1
          equal(event.pitch_index, entry.expected_note_pitch_indices_each_cycle[n], entry.id)
          equal(event.note, entry.expected_note_values_each_cycle[n], entry.id)
          if n == 1 then equal(event.transition, entry.expected_first_transitions[cycle], entry.id) end
        end
      end
    end
  else
    local p = seq.new_pattern(entry.length)
    p.pitch_length = entry.pitch_length
    if entry.input_time then
      for step,command in ipairs(entry.input_time) do p.time_events[step]=command end
    else
      for i=1,entry.length do p.time_events[i] = 'R' end
    end
    local plan, err = interpreter.compile_cycle(p)
    assert(not plan and err, entry.id)
    if entry.expected_error == 'leading_tie' then
      assert(err:find('leading TIE', 1, true), entry.id)
      equal(p.time_events[1], 'T', entry.id .. ' source unchanged')
    end
  end
end

local family = oracle.boundary_family
for _, length_case in ipairs(family.length_cases) do
  if length_case.length<=seq.MAX_STEPS then
  local p = seq.new_pattern(length_case.length)
  p.pitch_length = 32
  for i=1,32 do
    p.pitch_events[i] = pitch(24+(i-1)%37,false,
      i==15 or i==30 or i==45 or i==60)
  end
  for i=1,p.length do p.time_events[i] = family.source_generator.time_overrides[tostring(i)] or 'N' end
  local plans, final_state = assert(interpreter.compile_cycles(p, 3))
  for cycle, plan in ipairs(plans) do
    equal(plan.steps[1].transition, length_case.first_transitions[cycle], 'boundary first transition')
    equal(plan.note_count, length_case.note_count, 'boundary note count')
    for _, checkpoint in ipairs(family.expected_checkpoint_each_cycle) do
      if checkpoint.step <= p.length then
        local event = plan.steps[checkpoint.step]
        equal(event.kind, checkpoint.kind, 'boundary kind')
        if event.kind == 'note' then
          equal(event.pitch_index, checkpoint.pitch_index, 'boundary pitch')
          equal(event.note, checkpoint.note, 'boundary note')
          equal(event.transition, checkpoint.transition, 'boundary transition')
        elseif event.kind == 'tie' then
          equal(event.pitch_index, checkpoint.voice_pitch_index, 'boundary tie pitch')
          equal(event.note, checkpoint.voice_note, 'boundary tie note')
          equal(event.holds, checkpoint.holds, 'boundary tie holds')
        else
          equal(event.releases, checkpoint.releases, 'boundary rest')
          equal(event.released_note, checkpoint.released_note, 'boundary release note')
        end
        if checkpoint.hold_intent ~= nil then
          equal(event.hold_intent, checkpoint.hold_intent, 'boundary hold intent')
        end
      end
    end
  end
  equal(final_state.next_pitch, length_case.exit_next_pitch, 'boundary exit cursor')
  if length_case.exit_voice == json.null then
    equal(final_state.voice, nil, 'boundary exit voice')
  else
    for _, key in ipairs({'note','pitch_index','slide'}) do
      equal(final_state.voice[key], length_case.exit_voice[key], 'boundary exit ' .. key)
    end
  end
  end
end

for _, length in ipairs({1,16,17,31,32}) do
  for _, command in ipairs({'N','R'}) do
    local p = seq.new_pattern(length)
    p.pitch_length = 32
    for i=1,length do p.time_events[i] = command end
    local plans = assert(interpreter.compile_cycles(p, 3))
    for cycle, plan in ipairs(plans) do
      for i, event in ipairs(plan.steps) do
        if command == 'N' then
          equal(event.pitch_index, i, 'all-note pitch index')
          equal(event.transition, cycle == 1 and i == 1 and 'attack' or 'retrigger', 'all-note transition')
        else
          equal(event.releases, false, 'all-rest release')
        end
      end
    end
  end
end

local p = seq.new_pattern(3)
p.pitch_length = 1
p.pitch_events[1] = seq.new_pitch(3, -1, true, true)
p.time_events[1],p.time_events[2],p.time_events[3] = 'N','T','N'
local plans, state = assert(interpreter.compile_cycles(p, 3))
equal(plans[1].steps[1].octave, -1, 'octave preserved')
equal(plans[1].steps[2].voice.accent, true, 'accent retained on tie')
equal(plans[2].steps[1].transition, 'slide', 'outgoing slide at wrap')
equal(p.pitch_events[1].octave, -1, 'source remains unchanged')
plans[1].steps[2].voice.note = 0
equal(state.voice.note, p.pitch_events[1].note, 'events do not alias exit voice')
equal(p.pitch_events[1].note, 27, 'events do not alias source')
local incoming_pitch=pitch(40,true,true)
incoming_pitch.pitch_index=7
local incoming = {cycle=2,next_pitch=17,voice=incoming_pitch}
local first, returned = assert(interpreter.compile_cycle(p, incoming))
equal(first.steps[1].pitch_index, 1, 'pitch cursor resets independently of voice')
equal(first.steps[1].from_note, 40, 'incoming voice preserved')
equal(incoming.voice.note, 40, 'incoming state remains unchanged')
returned.voice.note = 0
equal(incoming.voice.note, 40, 'returned state does not alias input')
local last, exhausted = interpreter.compile_cycles(p, 1, {cycle=1000000})
assert(last and exhausted.cycle==1000001)
assert(not interpreter.compile_cycle(p, exhausted))
assert(not interpreter.compile_cycles(p, 2, {cycle=1000000}))
p.time_events[1] = 'T'
assert(not interpreter.compile_cycle(p))
assert(not interpreter.compile_cycles(p, 0))
assert(not interpreter.compile_cycles(p, interpreter.MAX_CYCLES+1))
assert(not interpreter.compile_cycle(p, {cycle=1, voice=pitch(36)}))
assert(not pcall(seq.new_pattern,33))
assert(seq.normalize_time_entry(32, 'T')=='T')
assert(not seq.normalize_time_entry(33, 'T'))
assert(not seq.normalize_time_entry(1, 'X'))

print('ACID repeating cycle interpreter checks passed')
