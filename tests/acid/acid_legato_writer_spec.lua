dofile('tests/bootstrap.lua')('acid')
local seq=require('model.sequencer')
local compiler=require('model.cycle_interpreter')
local control=require('model.control_signals')
local planner=require('model.legato')
local writer=require('writers.legato_writer')
local validator=require('writers.phrase_validator')
local columns=dofile('tests/acid/phrase_columns.lua')

local source=seq.new_pattern(4)
source.pitch_length=2
source.pitch_events[1]=seq.new_pitch(0,0,false,true)
source.pitch_events[2]=seq.new_pitch(7,0,true,false)
source.time_events[1],source.time_events[2]='N','T'
source.time_events[3],source.time_events[4]='N','R'
local semantic=assert(compiler.compile_cycle(source))
local layout={number_of_lines=16,looping=false,loop_start=1,loop_end=16,
  length=4,physical_steps=4,cycle_count=1,sentinel_lines=0,
  lines_per_step=4,half_step_lines=2,lpb=16}
local timeline=assert(control.compile(source,{plan=semantic,output_policy='play_once'}))
local native=assert(planner.plan(semantic,timeline,layout))
local phrase={number_of_lines=16,looping=false,loop_start=1,loop_end=16,lpb=16,shuffle=0,
  visible_note_columns=1,visible_effect_columns=0,cells={}}
for line=1,16 do phrase.cells[line]={note_value=121} end
function phrase:line(index) return columns.line(self,index) end
assert(writer.apply(phrase,native))
assert(phrase.visible_note_columns==2 and phrase.delay_column_visible)
local target=phrase:line(9).note_columns
assert(target[2].note_value==43 and target[2].volume_value==255)
assert(target[1].note_value==120 and target[1].delay_value==1)
assert(phrase:line(13).note_columns[2].note_value==120)
local result,err=validator.verify(phrase,semantic,4,layout,{native_notes=native})
assert(result,err)
assert(result.notes==2 and result.offs==2)

-- Missing overlap or a hidden sample command must fail final validation.
target[1].delay_value=0
assert(not validator.verify(phrase,semantic,4,layout,{native_notes=native}))
target[1].delay_value=1
target[2].effect_number_value=1
assert(not validator.verify(phrase,semantic,4,layout,{native_notes=native}))
target[2].effect_number_value=0
target[2].volume_value=89
assert(not validator.verify(phrase,semantic,4,layout,{native_notes=native}))
target[2].volume_value=255
assert(validator.verify(phrase,semantic,4,layout,{native_notes=native}))
print('ACID legato native emission, velocity and delayed release validation passed')
