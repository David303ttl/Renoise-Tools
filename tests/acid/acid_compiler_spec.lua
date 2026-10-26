dofile('tests/bootstrap.lua')('acid')
local sequencer = require("model.sequencer")
local compiler = require("model.compiler")

local function pattern(time, pitches)
  local p = sequencer.new_pattern(#time)
  p.time_events = time
  p.pitch_events = pitches
  return p
end

local p = pattern({"N", "T", "N", "R", "N"}, {
  {note=36, slide=true}, {note=39, accent=true}, {note=43}
})
local events = assert(compiler.compile(p))
assert(events.note_count == 3)
assert(events.steps[1].note == 36 and events.steps[1].transition == "attack")
assert(events.steps[2].kind == "tie" and events.steps[2].holds)
assert(events.steps[3].note == 39 and events.steps[3].transition == "slide")
assert(events.steps[3].from_note == 36 and events.steps[3].accent)
assert(events.steps[4].kind == "rest" and events.steps[4].releases)
assert(events.steps[5].note == 43 and events.steps[5].transition == "attack")
assert(events.boundary.loop_to_first_note == "retrigger")

local repeated = assert(compiler.compile(pattern({"N", "R", "N", "T", "N"}, {
  {note=36}, {note=40}
})))
assert(repeated.steps[3].note == 40)
assert(repeated.steps[4].holds and repeated.steps[4].note == 40)
assert(repeated.steps[5].note == 36 and repeated.steps[5].transition == "retrigger")

local same = assert(compiler.compile(pattern({"N", "N"}, {
  {note=36, slide=true}, {note=36}
})))
assert(same.steps[2].transition == "slide" and same.steps[2].from_note == 36)

local wrap = assert(compiler.compile(pattern({"N", "T", "N"}, {
  {note=36}, {note=40, slide=true}
})))
assert(wrap.boundary.loop_to_first_note == "slide")
assert(wrap.boundary.end_active and wrap.boundary.end_note == 40)

local broken = assert(compiler.compile(pattern({"N", "N", "R"}, {
  {note=36}, {note=40, slide=true}
})))
assert(broken.boundary.loop_to_first_note == "attack")

local leading = assert(compiler.compile(pattern({"T", "N", "N"}, {
  {note=36}, {note=40, slide=true}
})))
assert(leading.steps[1].holds == false) -- first pass from silence
assert(leading.boundary.leading_tie_holds_on_loop)
assert(leading.boundary.loop_to_first_note == "slide")

local empty = assert(compiler.compile(pattern({"R", "R"}, {})))
assert(empty.note_count == 0 and empty.boundary.loop_to_first_note == nil)
assert(not compiler.compile(pattern({"N", "R"}, {})))
assert(not compiler.compile(pattern({"N", "R"}, {{note=120}})))
assert(not compiler.compile({length=3,pitch_events={{note=36}},time_events={"N", "T"}}))

print("ACID semantic compiler checks passed")
