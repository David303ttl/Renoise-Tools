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
local pb_native=assert(planner.plan(semantic,timeline,layout,{pb_range=12,instrument_value=255}))
assert(next(pb_native.midi_commands))
assert(writer.apply(phrase,pb_native))
phrase.visible_note_columns=pb_native.columns+1
phrase.visible_effect_columns=2
assert(validator.verify(phrase,semantic,4,layout,{native_notes=pb_native}))
local extra_note=phrase:line(1).note_columns[phrase.visible_note_columns]
for _,field in ipairs({'delay_value','instrument_value','panning_value','volume_value','effect_number_value','effect_amount_value'})do
 local original=extra_note[field]
 extra_note[field]=1
 assert(not validator.verify(phrase,semantic,4,layout,{native_notes=pb_native}),field)
 extra_note[field]=original
end
local extra_effect=phrase:line(1).effect_columns[2]
for _,field in ipairs({'number_value','amount_value'})do
 extra_effect[field]=1
 assert(not validator.verify(phrase,semantic,4,layout,{native_notes=pb_native}),field)
 extra_effect[field]=0
end
assert(validator.verify(phrase,semantic,4,layout,{native_notes=pb_native}))
phrase.visible_note_columns=pb_native.columns-1
assert(not validator.verify(phrase,semantic,4,layout,{native_notes=pb_native}))
phrase.visible_note_columns=pb_native.columns+1
phrase.visible_effect_columns=0
assert(not validator.verify(phrase,semantic,4,layout,{native_notes=pb_native}))
local repeating={number_of_lines=17,looping=true,loop_start=9,loop_end=17,
 length=2,physical_steps=4,cycle_count=2,sentinel_lines=1,lines_per_step=4,lpb=16}
phrase.number_of_lines=17;phrase.looping=true;phrase.loop_start=9;phrase.loop_end=17
phrase.cells[17]={note_value=121}
assert(writer.apply(phrase,pb_native))
phrase.visible_note_columns=pb_native.columns+1;phrase.visible_effect_columns=2
local sentinel_articulation={native_notes=pb_native,volumes={[17]={[1]=255}}}
assert(validator.verify(phrase,semantic,4,repeating,sentinel_articulation))
phrase:line(17).note_columns[phrase.visible_note_columns].volume_value=89
assert(not validator.verify(phrase,semantic,4,repeating,sentinel_articulation))
print('ACID legato native emission, velocity and delayed release validation passed')
