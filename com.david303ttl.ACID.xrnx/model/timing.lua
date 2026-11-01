-- SPDX-License-Identifier: GPL-3.0-only
-- Integer musical timing and native phrase layout.
local sequencer=require("model.sequencer")
local policies=require("model.policies")
local M = {}
local UNITS_PER_BEAT=24
local STRAIGHT_UNITS_PER_STEP=6
local TRIPLET_UNITS_PER_STEP=8
local STRAIGHT_LPB=16
local TRIPLET_LPB=12
local TRIPLET_RESOLUTION_NUMERATOR=2
local TRIPLET_RESOLUTION_DENOMINATOR=3
local TRIPLET_PULSE_RESOLUTION=TRIPLET_RESOLUTION_NUMERATOR/TRIPLET_RESOLUTION_DENOMINATOR
local STRAIGHT_PULSE_UNIT="1/16"
local TRIPLET_PULSE_UNIT="1/8"
local STRAIGHT_PULSE_RESOLUTION=1
local STRAIGHT_PULSE_RESOLUTION_SOURCE="1"
local TRIPLET_PULSE_RESOLUTION_SOURCE="2/3"
local LINES_PER_STEP=4
local HALF_STEPS_PER_STEP=2
local SINGLE_CYCLE=1
local REPEAT_CYCLES=2
local EXCLUSIVE_END_SENTINEL_LINES=1
local FIRST_PHRASE_LINE=1
M.LINES_PER_STEP=LINES_PER_STEP
M.REPEAT_CYCLES=REPEAT_CYCLES
M.EXCLUSIVE_END_SENTINEL_LINES=EXCLUSIVE_END_SENTINEL_LINES
M.STRAIGHT_PULSE_UNIT=STRAIGHT_PULSE_UNIT
M.TRIPLET_PULSE_UNIT=TRIPLET_PULSE_UNIT
M.STRAIGHT_PULSE_RESOLUTION=STRAIGHT_PULSE_RESOLUTION
M.TRIPLET_PULSE_RESOLUTION=TRIPLET_PULSE_RESOLUTION
M.STRAIGHT_PULSE_RESOLUTION_SOURCE=STRAIGHT_PULSE_RESOLUTION_SOURCE
M.TRIPLET_PULSE_RESOLUTION_SOURCE=TRIPLET_PULSE_RESOLUTION_SOURCE
local modes = {
  straight = {units_per_step=STRAIGHT_UNITS_PER_STEP, lpb=STRAIGHT_LPB,
    unit=STRAIGHT_PULSE_UNIT, resolution=STRAIGHT_PULSE_RESOLUTION},
  triplet = {units_per_step=TRIPLET_UNITS_PER_STEP, lpb=TRIPLET_LPB,
    unit=TRIPLET_PULSE_UNIT, resolution=TRIPLET_PULSE_RESOLUTION}
}

function M.valid_mode(mode)
  return modes[mode] ~= nil
end

function M.new(mode, length, output_policy)
  local spec=modes[mode]
  if not spec then return nil,"Invalid timing mode" end
  if not policies.in_integer_range(length,1,sequencer.MAX_STEPS) then
    return nil,"Invalid timing length"
  end
  if spec.lpb*spec.units_per_step/UNITS_PER_BEAT~=LINES_PER_STEP then
    return nil,"timing mode does not match the phrase-line layout"
  end
  if not policies.valid_output_policy(output_policy) then
    return nil,"Invalid phrase output policy"
  end
  local repeating=output_policy=="repeat"
  local cycle_count=repeating and REPEAT_CYCLES or SINGLE_CYCLE
  local physical_steps=length*cycle_count
  local lines_per_step=LINES_PER_STEP
  local musical_lines=length*lines_per_step
  local sentinel_lines=repeating and EXCLUSIVE_END_SENTINEL_LINES or 0
  local number_of_lines=physical_steps*lines_per_step+sentinel_lines
  local layout={mode=mode, length=length, units_per_beat=UNITS_PER_BEAT,
    units_per_step=spec.units_per_step, lpb=spec.lpb, unit=spec.unit,
    resolution=spec.resolution, lines_per_step=lines_per_step,
    half_step_lines=lines_per_step/HALF_STEPS_PER_STEP, cycle_count=cycle_count,
    physical_steps=physical_steps, sentinel_lines=sentinel_lines,
    looping=repeating,
    loop_start=repeating and musical_lines+FIRST_PHRASE_LINE or FIRST_PHRASE_LINE,
    loop_end=repeating and number_of_lines or musical_lines,
    number_of_lines=number_of_lines}
  local function check_step(step)
    assert(type(step)=="number" and step%1==0 and step>=1 and step<=physical_steps,
      "invalid physical step")
  end
  function layout.start_units(step) check_step(step);return (step-1)*layout.units_per_step end
  function layout.mid_units(step)
    return layout.start_units(step)+layout.units_per_step/HALF_STEPS_PER_STEP
  end
  function layout.start_line(step)
    check_step(step)
    return (step-FIRST_PHRASE_LINE)*layout.lines_per_step+FIRST_PHRASE_LINE
  end
  function layout.mid_line(step)
    return layout.start_line(step)+layout.half_step_lines
  end
  function layout.source_step(step) check_step(step);return ((step-1)%length)+1 end
  return setmetatable({}, {__index=layout, __newindex=function()
    error("timing layout is immutable",2)
  end, __metatable=false})
end
return M

