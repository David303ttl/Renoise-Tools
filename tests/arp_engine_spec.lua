local engine = dofile("com.david303ttl.ARP.xrnx/arp_engine.lua")
local function joined(mode)
  return table.concat(engine.order_notes({67,60,64}, mode), ",")
end
assert(joined("up") == "60,64,67")
assert(joined("down") == "67,64,60")
assert(joined("up_down") == "60,64,67,64")
assert(#engine.order_notes({}, "up_down") == 0)
assert(table.concat(engine.order_notes({60}, "up_down"), ",") == "60")
assert(engine.rate_lines(4, "1/4") == 4)
assert(engine.rate_lines(4, "1/8") == 2)
assert(engine.rate_lines(4, "1/16") == 1)
assert(engine.rate_lines(4, "1/32") == nil)
assert(engine.rate_lines(8, "1/32") == 1)
assert(table.concat(engine.expand_notes({60,64}, 2, "up"), ",") == "60,64,72,76")
assert(table.concat(engine.expand_notes({60,64}, 2, "down"), ",") == "76,72,64,60")
assert(table.concat(engine.expand_notes({114}, 2, "up"), ",") == "114")
local chords = {
  {line = 1, notes = {67,60,64}, instrument = 0},
  {line = 9, notes = {72}, instrument = 1}
}
local events = engine.generate(chords, 16, 2, "up")
assert(#events == 8)
assert(events[1].line == 1 and events[1].note == 60)
assert(events[5].line == 9 and events[5].note == 72)
local oct = engine.generate({{line=1,notes={60},instrument=0}}, 8, 2, "up", 2)
assert(oct[1].note == 60 and oct[2].note == 72 and oct[3].note == 60)
print("ARP musical rate, octave and scheduling checks passed")
