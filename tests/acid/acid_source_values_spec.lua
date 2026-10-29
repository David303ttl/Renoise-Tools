dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local store=require("model.pattern_store")

local source=seq.new_pattern(4)
source.pitch_events[32]=seq.new_pitch(12,1,true,true)
source.time_events[32]="R"
local copy=assert(seq.copy_source(source))
assert(seq.same_source(source,copy))
assert(not rawequal(source,copy) and not rawequal(source.pitch_events,copy.pitch_events)
  and not rawequal(source.time_events,copy.time_events))
for i=1,seq.MAX_STEPS do
  assert(not rawequal(source.pitch_events[i],copy.pitch_events[i]))
end
for _,field in ipairs({"length","pitch_length","timing_mode"}) do
  local changed=assert(seq.copy_source(source))
  changed[field]=field=="timing_mode" and "triplet" or changed[field]+1
  assert(not seq.same_source(source,changed),field)
end
for i=1,seq.MAX_STEPS do
  for _,field in ipairs({"note","key","octave","accent","slide"}) do
    local changed=assert(seq.copy_source(source))
    local pitch=changed.pitch_events[i]
    if field=="note" or field=="key" or field=="octave" then
      changed.pitch_events[i]=seq.new_pitch(pitch.key==0 and 1 or 0,
        field=="octave" and (pitch.octave==0 and 1 or 0) or pitch.octave,
        pitch.accent,pitch.slide)
    else pitch[field]=not pitch[field] end
    assert(not seq.same_source(source,changed),field.." at "..i)
  end
  local changed=assert(seq.copy_source(source))
  changed.time_events[i]=changed.time_events[i]=="R" and "N" or "R"
  assert(not seq.same_source(source,changed),"time at "..i)
end
copy.pitch_events[32].accent=false
copy.time_events[32]="N"
assert(source.pitch_events[32].accent and source.time_events[32]=="R")
for _,invalid in ipairs({false,0,"source",{}, {length=4,pitch_events={}}}) do
  local value,err=seq.copy_source(invalid)
  assert(value==nil and type(err)=="string")
  assert(not seq.same_source(invalid,invalid))
end
assert(not seq.copy_source(nil) and not seq.same_source(nil,nil))
local invalid=assert(seq.copy_source(source))
invalid.pitch_events[1].extra={}
assert(not seq.copy_source(invalid))

local song={tool_data=nil}
local prepared=assert(store.prepare(song,1,source,"play_once",12,function()return true end))
local expected=prepared.raw
source.length=8
source.pitch_events[32].accent=false
source.time_events[32]="N"
assert(prepared.raw==expected and store.commit(song,prepared))
local saved=assert(store.read(song))[1]
assert(saved.pattern.length==4 and saved.pattern.pitch_events[32].accent
  and saved.pattern.time_events[32]=="R" and saved.output_policy=="play_once"
  and saved.pb_range==12)
print("acid_source_values_spec: OK")
