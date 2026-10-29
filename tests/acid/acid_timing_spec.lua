dofile('tests/bootstrap.lua')('acid')
local timing=require('model.timing')
local sequencer=require('model.sequencer')
local compiler=require('model.cycle_interpreter')
local pattrns=require('writers.pattrns_writer')
local output_planner=require('model.output_planner')

-- Fixed musical examples: 12 straight steps span three beats, while 32
-- triplet steps span ten beats and two triplet subdivisions.
local examples={
  {mode='straight', length=12, policy='play_once', lpb=16, lines=48,
    loop_start=1, loop_end=48, points={{1,0,3,1,3,1},{12,66,69,45,47,12}}},
  {mode='straight', length=12, policy='repeat', lpb=16, lines=97,
    loop_start=49, loop_end=97, points={{12,66,69,45,47,12},
      {13,72,75,49,51,1},{24,138,141,93,95,12}}},
  {mode='triplet', length=32, policy='play_once', lpb=12, lines=128,
    loop_start=1, loop_end=128, points={{1,0,4,1,3,1},{12,88,92,45,47,12},
      {17,128,132,65,67,17},{32,248,252,125,127,32}}},
  {mode='triplet', length=32, policy='repeat', lpb=12, lines=257,
    loop_start=129, loop_end=257, points={{32,248,252,125,127,32},
      {33,256,260,129,131,1},{64,504,508,253,255,32}}}
}
for _,example in ipairs(examples) do
  local layout=assert(timing.new(example.mode,example.length,example.policy))
  assert(layout.lpb==example.lpb and layout.number_of_lines==example.lines)
  assert(layout.loop_start==example.loop_start and layout.loop_end==example.loop_end)
  for _,point in ipairs(example.points) do
    local step=point[1]
    assert(layout.start_units(step)==point[2] and layout.mid_units(step)==point[3])
    assert(layout.start_line(step)==point[4] and layout.mid_line(step)==point[5])
    assert(layout.source_step(step)==point[6])
  end
end

for _,mode in ipairs({'straight','triplet'}) do
  for n=1,32 do
    for _,policy in ipairs({'play_once','repeat'}) do
      local layout=assert(timing.new(mode,n,policy))
      local units=mode=='straight' and 6 or 8
      assert(layout.units_per_beat==24 and layout.units_per_step==units)
      assert(layout.lpb==(mode=='straight' and 16 or 12))
      assert(layout.lines_per_step==4)
      assert(layout.number_of_lines==(policy=='repeat' and 8*n+1 or 4*n))
      assert(layout.loop_start==(policy=='repeat' and 4*n+1 or 1))
      assert(layout.loop_end==layout.number_of_lines)
      for s=1,layout.physical_steps do
        assert(layout.start_units(s)==(s-1)*units and layout.mid_units(s)==(s-1)*units+units/2)
        assert(layout.start_line(s)==(s-1)*4+1 and layout.mid_line(s)==(s-1)*4+3)
        assert(layout.source_step(s)==(s-1)%n+1)
      end
      assert(not pcall(layout.start_line,0) and not pcall(layout.mid_units,1.5))
      assert(not pcall(layout.source_step,layout.physical_steps+1))
      assert(not pcall(function() layout.lpb=4 end))
      local pattern=sequencer.new_pattern(n)
      pattern.timing_mode=mode
      local plan,output=assert(output_planner.plan_output(pattern,policy,512))
      assert(output.lpb==layout.lpb and output.number_of_lines==layout.number_of_lines)
      local script=assert(pattrns.emit(plan,{unit=layout.unit,resolution=layout.resolution}))
      assert(script:find('unit = "'..layout.unit..'"',1,true))
      assert(script:find('resolution = '..(mode=='straight' and '1' or '2/3'),1,true))
    end
  end
end
assert(not timing.new('unknown',16,'repeat'))
assert(not timing.new('straight',33,'repeat'))
assert(not timing.new('straight',16,'bad'))
print('ACID integer timing and physical layouts passed')
