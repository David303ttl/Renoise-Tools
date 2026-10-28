dofile('tests/bootstrap.lua')('acid')
local timing=require('model.timing')
local sequencer=require('model.sequencer')
local compiler=require('model.cycle_interpreter')
local pattrns=require('writers.pattrns_writer')
local writer=require('writers.phrase_writer')

-- Fixed musical examples: 12 straight steps span three beats, while 64
-- triplet steps span 21 beats and one triplet subdivision.
local examples={
  {mode='straight', length=12, policy='play_once', lpb=8, lines=24,
    loop_start=1, loop_end=24, points={{1,0,3,1,2,1},{12,66,69,23,24,12}}},
  {mode='straight', length=12, policy='repeat', lpb=8, lines=49,
    loop_start=25, loop_end=49, points={{12,66,69,23,24,12},
      {13,72,75,25,26,1},{24,138,141,47,48,12}}},
  {mode='triplet', length=64, policy='play_once', lpb=6, lines=128,
    loop_start=1, loop_end=128, points={{1,0,4,1,2,1},{12,88,92,23,24,12},
      {33,256,260,65,66,33},{49,384,388,97,98,49},{64,504,508,127,128,64}}},
  {mode='triplet', length=64, policy='repeat', lpb=6, lines=257,
    loop_start=129, loop_end=257, points={{64,504,508,127,128,64},
      {65,512,516,129,130,1},{128,1016,1020,255,256,64}}}
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
  for n=1,64 do
    for _,policy in ipairs({'play_once','repeat'}) do
      local layout=assert(timing.new(mode,n,policy))
      local units=mode=='straight' and 6 or 8
      assert(layout.units_per_beat==24 and layout.units_per_step==units)
      assert(layout.lpb==(mode=='straight' and 8 or 6))
      assert(layout.number_of_lines==(policy=='repeat' and 4*n+1 or 2*n))
      assert(layout.loop_start==(policy=='repeat' and 2*n+1 or 1))
      assert(layout.loop_end==layout.number_of_lines)
      for s=1,layout.physical_steps do
        assert(layout.start_units(s)==(s-1)*units and layout.mid_units(s)==(s-1)*units+units/2)
        assert(layout.start_line(s)==2*s-1 and layout.mid_line(s)==2*s)
        assert(layout.source_step(s)==(s-1)%n+1)
      end
      assert(not pcall(layout.start_line,0) and not pcall(layout.mid_units,1.5))
      assert(not pcall(layout.source_step,layout.physical_steps+1))
      assert(not pcall(function() layout.lpb=4 end))
      local pattern=sequencer.new_pattern(n)
      pattern.timing_mode=mode
      local plan,output=assert(writer.plan_output(pattern,policy))
      assert(output.lpb==layout.lpb and output.number_of_lines==layout.number_of_lines)
      local script=assert(pattrns.emit(plan,{unit=layout.unit,resolution=layout.resolution}))
      assert(script:find('unit = "'..layout.unit..'"',1,true))
      assert(script:find('resolution = '..(mode=='straight' and '1' or '2/3'),1,true))
    end
  end
end
assert(not timing.new('unknown',16,'repeat'))
assert(not timing.new('straight',65,'repeat'))
assert(not timing.new('straight',16,'bad'))
print('ACID integer timing and physical layouts passed')
