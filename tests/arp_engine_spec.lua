-- Run from the repository root: lua tests/arp_engine_spec.lua
local engine = dofile("com.david303ttl.ARP.xrnx/arp_engine.lua")
local function joined(mode)
  return table.concat(engine.order_notes({67,60,64}, mode), ",")
end
assert(joined("up") == "60,64,67")
assert(joined("down") == "67,64,60")
assert(joined("up_down") == "60,64,67,64")
assert(#engine.order_notes({}, "up_down") == 0)
assert(table.concat(engine.order_notes({60}, "up_down"), ",") == "60")
local chords = {
  {line = 1, notes = {67,60,64}, instrument = 0},
  {line = 9, notes = {72}, instrument = 1}
}
local events = engine.generate(chords, 16, 2, "up")
assert(#events == 8)
assert(events[1].line == 1 and events[1].note == 60)
assert(events[2].line == 3 and events[2].note == 64)
assert(events[3].line == 5 and events[3].note == 67)
assert(events[4].line == 7 and events[4].note == 60)
assert(events[5].line == 9 and events[5].note == 72)
assert(events[8].line == 15 and events[8].instrument == 1)
print("ARP ordering and schedule checks passed")
