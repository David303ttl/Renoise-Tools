-- Run at repository root: lua tests/arp_engine_spec.lua
local engine = dofile("com.david303ttl.ARP.xrnx/arp_engine.lua")

local function joined(mode)
  return table.concat(engine.order_notes({67, 60, 64}, mode), ",")
end

assert(joined("up") == "60,64,67")
assert(joined("down") == "67,64,60")
assert(joined("up_down") == "60,64,67,64")
assert(#engine.order_notes({}, "up_down") == 0)
assert(table.concat(engine.order_notes({60}, "up_down"), ",") == "60")

print("ARP ordering checks passed")
