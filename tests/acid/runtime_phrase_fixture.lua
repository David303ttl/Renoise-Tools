dofile('tests/bootstrap.lua')('acid')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')
local planner=require('model.output_planner')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local phrase_fixture=dofile('tests/acid/complete_phrase_fixture.lua')
renoise={InstrumentPhrase={MAX_NUMBER_OF_LINES=512,MAX_NUMBER_OF_NOTE_COLUMNS=12,
 MAX_NUMBER_OF_EFFECT_COLUMNS=8,PLAY_PATTERN=1,KEY_TRACKING_NONE=1},
 Instrument={MAX_NUMBER_OF_PHRASES=126,PHRASES_OFF=1},Transport={TIMING_MODEL_LPB=1}}
local capacities={max_lines=512,max_note_columns=12,max_effect_columns=8,
 play_pattern=1,key_tracking_none=1}
local profile={sample=true,plugin=false,midi=false,alias=false}
local eq_calls=0
local content_equality={__eq=function()eq_calls=eq_calls+1;return true end}
local function phrase(source,id)
 local p=phrase_fixture()
 local plan=assert(planner.plan(source,'play_once',0,capacities,profile,{pitch_bend_delivery=true}))
 for key,value in pairs(plan.expected.properties)do p[key]=value end
 for key,value in pairs(plan.required_visibility)do p[key]=value end
 for index,line in ipairs(plan.expected.lines)do
  for column,cell in ipairs(line.note_columns)do
   for key,value in pairs(cell)do p.lines[index].note_columns[column][key]=value end
  end
  for column,cell in ipairs(line.effect_columns)do
   for key,value in pairs(cell)do p.lines[index].effect_columns[column][key]=value end
  end
 end
 p.name=assert(ownership.make_name(p,id))
 return setmetatable(p,content_equality)
end
local function instrument(phrases)
 return {name='Sampler',phrases=phrases,samples={{sample_buffer={has_sample_data=true}}},
  plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,
   alias_fx_device_index=0,midi_output_routing_index=0},
  midi_output_properties={device_name='',instrument_type=1,channel=1},
  phrase_playback_mode=2,phrase_program=1}
end
local function runtime(song,temporary)
 local ctx=context.new{writer={state=function()return 'idle',nil end,
  is_temporary=function(_,_,p)return rawequal(p,temporary)end},
  capture=function()error('inventory must not capture')end,
  sink=function()error('inventory must not render')end}
 ctx:attach_document(song);ctx:open_dialog()
 return ctx
end
local function fixture()
 local source=seq.new_pattern(4)
 local a,b=phrase(source,101),phrase(source,102)
 local inst=instrument({a,b})
 local song={instruments={inst},tool_data='',transport={timing_model=1,groove_enabled=false},
  is_undo_redoing=function()return false end}
 assert(store.save(song,101,source,'play_once',0))
 assert(store.save(song,102,source,'play_once',0))
 return song,inst,a,b,source
end
return {fixture=fixture,phrase=phrase,instrument=instrument,runtime=runtime,eq_calls=function()return eq_calls end}
