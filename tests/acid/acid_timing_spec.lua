dofile('tests/bootstrap.lua')('acid')
local timing=require('model.timing')
local sequencer=require('model.sequencer')
local compiler=require('model.cycle_interpreter')
local pattrns=require('writers.pattrns_writer')
local writer=require('writers.phrase_writer')
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
