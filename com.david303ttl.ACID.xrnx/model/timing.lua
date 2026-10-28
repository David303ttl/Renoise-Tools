-- SPDX-License-Identifier: GPL-3.0-only
-- Integer musical timing and native phrase layout.
local M = {}
local modes = {
  straight = {units_per_step=6, lpb=8, unit="1/16", resolution=1},
  triplet = {units_per_step=8, lpb=6, unit="1/8", resolution=2/3}
}

function M.valid_mode(mode)
  return modes[mode] ~= nil
end

function M.new(mode, length, output_policy)
  local spec=modes[mode]
  if not spec then return nil,"Invalid timing mode" end
  if type(length)~="number" or length%1~=0 or length<1 or length>64 then
    return nil,"Invalid timing length"
  end
  if output_policy~="repeat" and output_policy~="play_once" then
    return nil,"Invalid phrase output policy"
  end
  local repeating=output_policy=="repeat"
  local physical_steps=length*(repeating and 2 or 1)
  local layout={mode=mode, length=length, units_per_beat=24,
    units_per_step=spec.units_per_step, lpb=spec.lpb, unit=spec.unit,
    resolution=spec.resolution, lines_per_step=2, physical_steps=physical_steps,
    looping=repeating, loop_start=repeating and 2*length+1 or 1,
    loop_end=repeating and 2*physical_steps+1 or 2*length,
    number_of_lines=2*physical_steps+(repeating and 1 or 0)}
  local function check_step(step)
    assert(type(step)=="number" and step%1==0 and step>=1 and step<=physical_steps,
      "invalid physical step")
  end
  function layout.start_units(step) check_step(step);return (step-1)*layout.units_per_step end
  function layout.mid_units(step) return layout.start_units(step)+layout.units_per_step/2 end
  function layout.start_line(step) check_step(step);return 2*step-1 end
  function layout.mid_line(step) check_step(step);return 2*step end
  function layout.source_step(step) check_step(step);return ((step-1)%length)+1 end
  return setmetatable({}, {__index=layout, __newindex=function()
    error("timing layout is immutable",2)
  end, __metatable=false})
end
return M

