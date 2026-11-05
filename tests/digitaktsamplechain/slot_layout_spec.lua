dofile('tests/bootstrap.lua')('digitaktsamplechain')
local layout = require("slot_layout")
local settings = require("chain_options")
local function options(overrides)
  local result = settings.defaults()
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end
local RATE = settings.SAMPLE_RATE
local auto = assert(layout.plan({ 3, 5 }, options(), RATE))
assert(auto.slot_count == 2 and auto.slot_frames == 5 and auto.total_frames == 10)
assert(auto.slot_sec == 5 / RATE and auto.total_sec == 10 / RATE)
local fixed = assert(layout.plan({ 3, 5 }, options({ slot_count = 4 }), RATE))
assert(fixed.slot_frames == 5 and fixed.total_frames == 20)
local refused, why = layout.plan({ 1, 1, 1, 1, 1 }, options({ slot_count = 4 }), RATE)
assert(not refused and why:find("do not fit"))
assert(not layout.plan({}, options(), RATE))
assert(not layout.plan({ 1.5 }, options(), RATE))
assert(not layout.plan({ math.huge }, options(), RATE))

-- Every emitted slot boundary and reported duration agrees with the padded grid.
for _, count in ipairs({ 0, 4, 8, 16, 32, 64 }) do
  for _, pad in ipairs({ false, true }) do
    local opts = options({ zero_pad = pad })
    if count > 0 then opts.slot_count = count end
    local lengths = { 3, 5 }
    local plan = assert(layout.plan(lengths, opts, RATE))
    local slot_frames = 5 + (pad and 128 or 0)
    assert(plan.slot_frames == slot_frames)
    local emitted = 0
    for slot = 1, plan.slot_count do
      local length = lengths[slot]
      local read = length and function(frame)
        assert(frame >= 1 and frame <= length)
        return slot / 10
      end or nil
      local reader = layout.make_slot_reader(plan, read, length or 0)
      for frame = 1, slot_frames do
        local source_frame = frame - (pad and 64 or 0)
        local expected = length and source_frame >= 1 and source_frame <= length and slot / 10 or 0
        assert(reader(frame) == expected)
        emitted = emitted + 1
      end
    end
    assert(emitted == plan.total_frames)
    assert(plan.total_sec == emitted / RATE and plan.slot_sec == slot_frames / RATE)
  end
end

local chain = assert(layout.plan({ 2, 3 }, options({ mode = "chain", slot_count = 4, zero_pad = true }), RATE))
assert(chain.slot_count == 2 and chain.slot_frames == nil and chain.edge_silence == 0)
assert(chain.total_frames == 5 and chain.total_sec == 5 / RATE)
assert(chain.slot_sec == 2.5 / RATE, "chain mean must not discard fractional frames")
local no_fade = layout.make_slot_reader(chain, function() return 0.5 end, 3)
assert(no_fade(1) == 0.5 and no_fade(3) == 0.5)

for _, mode in ipairs({ "spaced", "chain" }) do
  local plan = assert(layout.plan({ 3 }, options({ mode = mode, fade = true }), 1000))
  assert(plan.fade_frames == 20)
  local read = layout.make_slot_reader(plan, function() return 0.5 end, 3)
  assert(read(1) == 0.5 and read(2) == 0.25 and read(3) == 0)
  local one = layout.make_slot_reader(plan, function() return 0.5 end, 1)
  assert(one(1) == 0)
  plan.fade_frames = 2
  read = layout.make_slot_reader(plan, function() return 0.5 end, 3)
  assert(read(1) == 0.5 and read(2) == 0.5 and read(3) == 0)
end
print("DigitaktSampleChain slot geometry, duration and fade specs passed")
