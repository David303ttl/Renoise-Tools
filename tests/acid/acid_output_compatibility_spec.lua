dofile('tests/bootstrap.lua')('acid')
local validator=require('writers.phrase_validator')
local ownership=require('renoise.phrase_ownership')
local planner=require('model.output_planner')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local phrase_fixture=dofile('tests/acid/complete_phrase_fixture.lua')
local capacities={max_lines=512,max_note_columns=12,max_effect_columns=8,play_pattern=1,key_tracking_none=1}
local sample={sample=true,plugin=false,midi=false,alias=false}
local options={pitch_bend_delivery=true}
local source=seq.new_pattern(4)
source.pitch_length=2
source.pitch_events[1]=seq.new_pitch(0,0,false,false)
source.pitch_events[2]=seq.new_pitch(7,0,true,false)
source.time_events[2]='T';source.time_events[4]='R'
local function output(pattern,policy,profile,pb)
 return assert(planner.plan(pattern,policy or 'play_once',pb or 0,capacities,profile or sample,options))
end
local function apply(phrase,planned)
 for key,value in pairs(planned.expected.properties)do phrase[key]=value end
 for key,value in pairs(planned.required_visibility)do phrase[key]=value end
 for line_index,line in ipairs(planned.expected.lines)do
  for column,cell in ipairs(line.note_columns)do
   for key,value in pairs(cell)do phrase.lines[line_index].note_columns[column][key]=value end
  end
  for column,cell in ipairs(line.effect_columns)do
   for key,value in pairs(cell)do phrase.lines[line_index].effect_columns[column][key]=value end
  end
 end
 phrase.name=assert(ownership.make_name(phrase,1))
end
local planned=output(source)
local phrase=phrase_fixture();apply(phrase,planned)
local instrument={name='complete fixture',phrases={phrase}}
local song={instruments={instrument},tool_data=''}
assert(store.save(song,1,source,'play_once',0))
local function classify(profile,opts)
 return validator.classify(song,instrument,phrase,profile or sample,capacities,opts or options)
end
local candidate=assert(classify())
assert(candidate.kind=='owned' and seq.same_source(candidate.source,source))
assert(validator.preflight(candidate.baseline,planned))
assert(ownership.compare(candidate.baseline,assert(ownership.snapshot(phrase))))
local before=song.tool_data
local draft=assert(seq.copy_source(source));draft.pitch_events[1]=seq.new_pitch(2,0,false,false)
assert(store.write_draft(song,instrument,phrase,draft,'repeat',12))
local with_draft=song.tool_data
assert(seq.same_source(assert(classify()).source,source))
assert(song.tool_data==with_draft)
local entry={pattern=source,output_policy='play_once',pb_range=0}
local standalone=assert(validator.compatibility(phrase,entry,sample,capacities,options))
source.pitch_events[32].accent=true
assert(not standalone.source.pitch_events[32].accent)
source.pitch_events[32].accent=false
-- Valid independent source and seal do not establish their association.
assert(store.save(song,1,draft,'play_once',0))
assert(ownership.status(phrase)=='owned' and store.load(song,instrument,phrase))
local rejected,reason,kind=classify()
assert(not rejected and reason:find('Committed',1,true) and kind=='unavailable')
package.loaded['writers.phrase_validator']=nil
validator=require('writers.phrase_validator')
assert(not classify())
assert(not validator.classify(song,instrument,phrase,sample,capacities,{draft=source,pitch_bend_delivery=true}))
assert(store.save(song,1,source,'play_once',0))
assert(classify())
local function rejects(object,key,changed)
 local old,name=object[key],phrase.name
 object[key]=changed;phrase.name=assert(ownership.make_name(phrase,1))
 local ok,message,status=classify()
 assert(not ok and message and status=='unavailable',key)
 object[key]=old;phrase.name=name
end
for _,key in ipairs({'number_of_lines','lpb','shuffle','loop_start','loop_end','playback_mode','key_tracking'})do
 rejects(phrase,key,phrase[key]+1)
end
rejects(phrase,'looping',not phrase.looping)
for _,key in ipairs({'note_value','instrument_value','volume_value','panning_value','delay_value','effect_number_value','effect_amount_value'})do
 local cell=phrase.lines[1].note_columns[1]
 rejects(cell,key,cell[key]==255 and 254 or cell[key]+1)
end
for _,key in ipairs({'number_value','amount_value'})do rejects(phrase.lines[1].effect_columns[1],key,1)end
rejects(phrase.lines[1].note_columns[1],'is_empty',true)
rejects(phrase.lines[1].effect_columns[1],'is_empty',false)
-- Extra visible empty columns are supported; hidden ancillary data is blocked.
phrase.visible_note_columns=12;phrase.visible_effect_columns=8;phrase.name=assert(ownership.make_name(phrase,1))
assert(classify())
apply(phrase,planned)
local note=phrase.lines[1].note_columns[12]
note.delay_value=1;note.is_empty=false
assert(not classify())
note.delay_value=0;note.is_empty=true
local tail=phrase.lines[512].note_columns[1]
tail.instrument_value=1;tail.is_empty=false
assert(not classify())
tail.instrument_value=255;tail.is_empty=true
local effect=phrase.lines[512].effect_columns[8]
effect.amount_value=1;effect.is_empty=false
assert(not classify())
effect.amount_value=0;effect.is_empty=true
rejects(phrase,'volume_column_visible',false)
local mapped={key_tracking=3,base_note=43,note_range={36,47},looping=true,loop_start=2,loop_end=14}
phrase.mapping=mapped
assert(classify())
local longer=assert(seq.copy_source(source));longer.length=8
local mapped_baseline=assert(ownership.snapshot(phrase))
assert(not validator.preflight(mapped_baseline,output(longer)))
assert(validator.preflight(mapped_baseline,planned))
phrase.mapping=nil
for _,update in ipairs({function(s)s.paragraphs={' '}end,function(s)s.paragraphs={'return pattern {}'}end,
 function(s)s.parameters={{name='sentinel',value=23}}end,function(s)s.pending_changes=1 end,
 function(s)s.editor_visible=false end})do
 local original=phrase.script
 phrase.script={paragraphs={},parameters={},pending_changes=0,editor_visible=true}
 update(phrase.script);assert(not classify());phrase.script=original
end
local old=phrase.lines[512].note_columns[12].volume_value
phrase.lines[512].note_columns[12].volume_value=nil
assert(not classify());phrase.lines[512].note_columns[12].volume_value=old
local old_script=phrase.script
phrase.script=setmetatable({},{__index=function()error('script access failed')end})
assert(not classify());phrase.script=old_script
local baseline=assert(ownership.snapshot(phrase))
for _,update in ipairs({function(p)p.base_note=p.base_note+1 end,function(p)p.autoseek=not p.autoseek end,
 function(p)p.column_names[12]='renamed' end,function(p)p.column_mutes[12]=true end,
 function(p)p.visible_note_columns=2 end})do
 local altered=phrase_fixture();apply(altered,planned);update(altered)
 assert(not ownership.compare(baseline,assert(ownership.snapshot(altered))))
end
-- Receiver-dependent output changes block, while unchanged output stays compatible.
local slide=assert(seq.copy_source(source));slide.time_events[2]='N';slide.pitch_events[2].slide=true
local plugin={sample=false,plugin=true,midi=false,alias=false}
local slide_phrase=phrase_fixture();apply(slide_phrase,output(slide,'play_once',plugin))
assert(validator.compatibility(slide_phrase,{pattern=slide,output_policy='play_once',pb_range=0},plugin,capacities,options))
assert(not validator.compatibility(slide_phrase,{pattern=slide,output_policy='play_once',pb_range=0},sample,capacities,options))
assert(not validator.compatibility(slide_phrase,{pattern=slide,output_policy='play_once',pb_range=0},{},capacities,options))
local foreign=phrase_fixture();instrument.phrases[2]=foreign
local foreign_result,_,foreign_kind=validator.classify(song,instrument,foreign,sample,capacities,options)
assert(not foreign_result and foreign_kind=='foreign');instrument.phrases[2]=nil
local detached=phrase_fixture();detached.name=phrase.name
local detached_result,_,detached_kind=validator.classify(song,instrument,detached,sample,capacities,options)
assert(not detached_result and detached_kind=='unavailable')
local collision=phrase_fixture();collision.name=phrase.name;instrument.phrases[2]=collision
assert(not classify());instrument.phrases[2]=nil
-- Read-only classification never invokes mutation or render methods.
for _,name in ipairs({'clear','copy_from','set_column_name','set_column_is_muted'})do phrase[name]=function()error('unexpected mutation')end end
phrase.script.commit=function()error('unexpected script commit')end
phrase.script.render_to_pattern=function()error('unexpected rendering')end
local raw=song.tool_data
assert(classify())
assert(song.tool_data==raw and ownership.compare(baseline,assert(ownership.snapshot(phrase))))
for _,case in ipairs({{profile=sample,pb=0},{profile=plugin,pb=2}})do
 local current_output=output(slide,'play_once',case.profile,case.pb)
 local current_phrase=phrase_fixture();apply(current_phrase,current_output)
 local current_baseline=assert(ownership.snapshot(current_phrase))
 assert(validator.preflight(current_baseline,current_output))
 for key,required in pairs(current_output.required_visibility)do
  if (type(required)=='boolean'and required)or(type(required)=='number'and required>0)then
   local changed=assert(ownership.copy_snapshot(current_baseline))
   if type(required)=='boolean'then changed.properties[key]=false else changed.properties[key]=required-1 end
   assert(not validator.preflight(changed,current_output),key)
  end
 end
end
local readonly=setmetatable({},{__index=phrase,__newindex=function()error('unexpected property write')end})
instrument.phrases[1]=readonly
local readonly_song=setmetatable({},{__index=song,__newindex=function()error('unexpected store write')end})
assert(validator.classify(readonly_song,instrument,readonly,sample,capacities,options))
instrument.phrases[1]=phrase
assert(not validator.compatibility(phrase,{pattern=source},sample,capacities,options))
assert(not validator.compatibility(phrase,{pattern=source,output_policy='play_once'},sample,capacities,options))
assert(not validator.classify(song,instrument,phrase,sample,capacities,1))
local poisoned=setmetatable({},{__index=function()error('options access was not rejected')end})
assert(not validator.classify(song,instrument,phrase,sample,capacities,poisoned))
assert(not validator.compatibility(phrase,entry,sample,capacities,poisoned))
local frozen=assert(classify())
assert(frozen.planning_inputs.capabilities.sample==true and frozen.planning_inputs.capacities.max_lines==512
 and frozen.planning_inputs.options.pitch_bend_delivery==true and frozen.planning_inputs.options.excluded==nil)
options.pitch_bend_delivery=false;capacities.max_lines=500;sample.sample=false
assert(frozen.planning_inputs.options.pitch_bend_delivery==true and frozen.planning_inputs.capacities.max_lines==512
 and frozen.planning_inputs.capabilities.sample==true)
options.pitch_bend_delivery=true;capacities.max_lines=512;sample.sample=true
print('ACID committed output compatibility and field preflight checks passed')



