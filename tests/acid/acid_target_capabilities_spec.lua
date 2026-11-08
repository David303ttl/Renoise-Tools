dofile('tests/bootstrap.lua')('acid')
local capabilities = require('renoise.target_capabilities')

local function target(sample, plugin, midi, alias)
  return {
    samples = sample and {{sample_buffer={has_sample_data=true}}} or {},
    plugin_properties = {
      plugin_loaded=plugin == true,
      alias_instrument_index=alias or 0,
      alias_fx_track_index=0,
      alias_fx_device_index=0,
      midi_output_routing_index=0,
    },
    midi_output_properties={device_name=midi or '',instrument_type=1,channel=1},
  }
end

local cases = {
  {target(true,false,''), 'sample'},
  {target(false,true,''), 'plugin'},
  {target(false,false,'Loopback'), 'midi'},
  {target(true,true,'Loopback'), 'hybrid'},
  {target(false,false,''), 'empty'},
  {target(false,true,'',4), 'plugin_alias'},
}
-- Renoise's type function reports API class names instead of Lua storage types.
local lua_type=type
local instrument_objects={}
for _,case in ipairs(cases) do instrument_objects[case[1]]=true end
_G.type=function(value)
  if lua_type(value)=='table' and instrument_objects[value] then return 'Instrument' end
  return lua_type(value)
end
for _,case in ipairs(cases) do
  local result=assert(capabilities.inspect(case[1]))
  assert(result.kind==case[2], 'unexpected target kind: '..result.kind)
  assert(capabilities.same(result,assert(capabilities.inspect(case[1]))))
  if result.kind=='empty' then assert(result.diagnostic:find('silent',1,true)) end
end
_G.type=lua_type
assert(not capabilities.inspect(nil))
assert(not capabilities.inspect(1))
assert(not capabilities.inspect('Instrument'))
local missing=assert(capabilities.inspect({}))
assert(missing.kind=='unknown' and missing.plugin==nil and missing.sample==nil and missing.read_error)
local failed=setmetatable({}, {__index=function() error('receiver read failed') end})
local unreadable=assert(capabilities.inspect(failed))
assert(unreadable.kind=='unknown' and unreadable.midi==nil and unreadable.read_error:find('receiver read failed',1,true))
local unreadable_again=assert(capabilities.inspect(failed))
assert(unreadable.read_error==unreadable_again.read_error)
assert(not capabilities.same(unreadable,unreadable_again),
  'identical failed inspections must not establish an unchanged target')
local malformed=target(false,false,'')
malformed.plugin_properties.alias_fx_track_index='missing'
assert(assert(capabilities.inspect(malformed)).kind=='unknown')
local unreadable_sample=target(false,false,'')
unreadable_sample.samples={{sample_buffer={}}}
assert(assert(capabilities.inspect(unreadable_sample)).kind=='unknown')

local instrument=target(false,true,'')
local before=assert(capabilities.inspect(instrument))
instrument.plugin_properties.plugin_loaded=false
instrument.midi_output_properties.device_name='MIDI Out'
local after=assert(capabilities.inspect(instrument))
assert(not capabilities.same(before,after), 'capability changes must invalidate a render target')
assert(after.kind=='midi' and after.diagnostic:find('MIDI',1,true))

local alias=target(false,false,'')
alias.plugin_properties.alias_fx_track_index=2
local unavailable=assert(capabilities.inspect(alias))
assert(unavailable.kind=='alias_unavailable' and unavailable.diagnostic)

_G.renoise={Instrument={PHRASES_OFF=1,PHRASES_PLAY_SELECTIVE=2},
  Midi={available_output_devices=function()return {'Connected Port'}end}}
local disconnected=target(false,false,'Removed Port')
local midi=assert(capabilities.inspect(disconnected))
assert(midi.midi_available==false and midi.diagnostic:find('unavailable',1,true))
local connected=target(false,false,'Connected Port')
assert(assert(capabilities.inspect(connected)).midi_available==true)

local phrase_target=target(false,true,'')
phrase_target.phrase_playback_mode=1
phrase_target.phrase_program=0
local phrase_off=assert(capabilities.inspect(phrase_target))
assert(phrase_off.diagnostic:find('mode is OFF',1,true))
assert(phrase_off.diagnostic:find('program is off',1,true))
phrase_target.phrase_playback_mode=2
phrase_target.phrase_program=1
local phrase_ready=assert(capabilities.inspect(phrase_target))
assert(not capabilities.same(phrase_ready,phrase_off) and phrase_ready.diagnostic==nil)

local mutations={
  function(value)value.samples={{sample_buffer={has_sample_data=true}}}end,
  function(value)value.plugin_properties.plugin_loaded=true end,
  function(value)value.plugin_properties.alias_instrument_index=1 end,
  function(value)value.plugin_properties.alias_fx_track_index=1 end,
  function(value)value.plugin_properties.alias_fx_device_index=1 end,
  function(value)value.plugin_properties.midi_output_routing_index=1 end,
  function(value)value.midi_output_properties.device_name='Other Port' end,
  function(value)value.midi_output_properties.instrument_type=2 end,
  function(value)value.midi_output_properties.channel=2 end,
  function(value)value.phrase_playback_mode=2 end,
  function(value)value.phrase_program=2 end,
  function()_G.renoise.Midi.available_output_devices=function()return {}end end,
}
for index,mutate in ipairs(mutations) do
  _G.renoise.Midi.available_output_devices=function()return {'Connected Port'}end
  local value=target(false,false,'Connected Port')
  value.phrase_playback_mode,value.phrase_program=1,1
  local baseline=assert(capabilities.inspect(value))
  mutate(value)
  local changed=assert(capabilities.inspect(value))
  assert(not capabilities.same(baseline,changed),'capability field mutation '..index..' was ignored')
end
local stable=target(false,false,'Connected Port')
local baseline=assert(capabilities.inspect(stable))
baseline.midi_device='tampered'
baseline.phrase_program=99
assert(capabilities.same(baseline,assert(capabilities.inspect(stable))),
  'public capability mutation changed the captured comparison contract')
assert(not capabilities.same({},{}),'uninspected capabilities must reject comparison')
assert(not capabilities.same(baseline,nil))
assert(not capabilities.same(baseline,missing))
assert(not capabilities.same(missing,assert(capabilities.inspect({}))),
  'two unknown profiles must not establish an unchanged target')

print('ACID target capability classification and change detection passed')
