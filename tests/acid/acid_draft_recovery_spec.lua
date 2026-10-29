dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local own=require("writers.phrase_ownership")
local store=require("model.pattern_store")
local validator=require("writers.phrase_validator")
local fixture=dofile("tests/acid/complete_phrase_fixture.lua")
local cache=require("model.draft_cache")
local committed=seq.new_pattern(1)
local function phrase(id)
  local p=fixture()
  p.number_of_lines=4;p.lpb=16;p.loop_end=4
  p.lines[1].note_columns[1].note_value=36
  p.lines[1].note_columns[1].volume_value=89
  p.lines[1].note_columns[1].is_empty=false
  p.lines[3].note_columns[1].note_value=120
  p.lines[3].note_columns[1].is_empty=false
  p.name=assert(own.make_name(p,id))
  return p
end
local a,b=phrase(1),phrase(2)
local instrument={name="Source",phrases={a,b},samples={{sample_buffer={has_sample_data=true}}},
  plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,
    alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""}}
local other={name="Scratch",phrases={}}
local song={instruments={instrument,other}}
renoise={song=function()return song end,InstrumentPhrase={MAX_NUMBER_OF_LINES=512,
  MAX_NUMBER_OF_NOTE_COLUMNS=12,MAX_NUMBER_OF_EFFECT_COLUMNS=8,PLAY_PATTERN=1,KEY_TRACKING_NONE=1}}
assert(store.save(song,1,committed,"play_once",0))
assert(store.save(song,2,committed,"play_once",0))
local original_classify=validator.classify
local checks=0
validator.classify=function(...)
  checks=checks+1
  return original_classify(...)
end
local dirty=seq.new_pattern(3)
dirty.pitch_events[2]=seq.new_pitch(7,0,true,false)
assert(cache.put(song,instrument,a,dirty,"repeat",12))
local restored,policy,pb,initial=cache.get(song,instrument,a)
assert(restored.length==3 and policy=="repeat" and pb==12)
assert(checks==2,"each draft access validates committed source/output")
restored.pitch_events[2].accent=false
assert(cache.get(song,instrument,a).pitch_events[2].accent)
assert(cache.get(song,instrument,b)==nil)
local saved,sp,sb,meta=cache.restore(song,instrument,b)
assert(saved.length==1 and sp=="play_once" and sb==0 and meta.origin=="committed")
local descriptor,guard=cache.capture(song,instrument,a)
assert(guard(descriptor.token,descriptor.revision))
local duplicate_owner=phrase(1)
other.phrases={duplicate_owner}
assert(not cache.is_current(song,descriptor),"a captured phrase ID must remain unique")
assert(not cache.compare_and_clear(song,descriptor),"duplicate ownership cannot clear a captured draft")
other.phrases={}
assert(cache.is_current(song,descriptor))
local live_token,live_revision=descriptor.token,descriptor.revision
instrument.phrases={b}
assert(not cache.is_current(song,descriptor) and not guard(live_token,live_revision))
assert(not cache.compare_and_clear(song,descriptor),"removed targets cannot clear a captured draft")
instrument.phrases={a,b}
assert(guard(live_token,live_revision))
local captured_token,captured_revision=descriptor.token,descriptor.revision
descriptor.instrument=other;descriptor.phrase=b;descriptor.kind="new"
descriptor.token=-1;descriptor.revision=-1
assert(guard(captured_token,captured_revision),"public descriptor mutation cannot retarget captured authority")
assert(not guard(-1,-1))
descriptor=assert(cache.capture(song,instrument,a))
local calls=checks
a.lines[1].note_columns[1].note_value=37
assert(cache.is_current(song,descriptor) and checks==calls,
  "commit token guard does not validate old output after authorized mutation")
a.lines[1].note_columns[1].note_value=36
local authorized=assert(cache.capture(song,instrument,a))
a.lines[1].note_columns[1].note_value=37
a.name=assert(own.make_name(a,1))
assert(cache.compare_and_clear(song,authorized),
  "a verified regeneration may change phrase content while retaining its unique ID")
a.lines[1].note_columns[1].note_value=36
a.name=assert(own.make_name(a,1))
assert(cache.put(song,instrument,a,seq.new_pattern(4),"repeat",0))
assert(cache.put(song,instrument,a,dirty,"repeat",12))
assert(not guard(descriptor.token,descriptor.revision),"equal-valued newer edits invalidate old revision")
assert(not cache.compare_and_clear(song,descriptor))
local latest=assert(cache.capture(song,instrument,a))
assert(latest.revision>initial.revision)
local candidate=assert(store.prepare(song,1,committed,"play_once",0,
  function(token,revision)return token==latest.token and revision==latest.revision and cache.is_current(song,latest)end,latest))
assert(store.commit(song,candidate))
assert(store.read_draft(song,instrument,a)==nil)
assert(cache.compare_and_clear(song,latest))
assert(not cache.get(song,instrument,a))

assert(cache.put(song,other,nil,dirty,"repeat",0))
local scratch_capture=assert(cache.capture(song,other,nil))
local original_instruments=song.instruments
song.instruments={other,instrument}
assert(not cache.is_current(song,scratch_capture),"reordered New Phrase bindings invalidate captured drafts")
assert(not cache.compare_and_clear(song,scratch_capture))
song.instruments=original_instruments
assert(cache.is_current(song,scratch_capture))
other.name="Renamed scratch"
assert(not cache.compare_and_clear(song,scratch_capture),"renamed New Phrase bindings cannot clear captured drafts")
other.name="Scratch"
assert(cache.is_current(song,scratch_capture))
assert(cache.clear(song,other,nil))

assert(cache.put(song,instrument,a,dirty,"repeat",12))
a.column_names[12]="changed preserved metadata"
assert(not cache.get(song,instrument,a))
assert(not cache.get(song,instrument,a),"detached drafts cannot rehydrate against a newer baseline")
local entries=cache.list(song)
assert(#entries==1 and entries[1].pattern.length==3 and entries[1].session_only)
local token=entries[1].token
entries[1].pattern.pitch_events[2].accent=false
assert(cache.list(song)[1].pattern.pitch_events[2].accent)
local function values_only(value)
  local kind=type(value)
  assert(kind=="table" or kind=="number" or kind=="boolean" or kind=="string")
  if kind=="table" then assert(getmetatable(value)==nil);for _,item in pairs(value)do values_only(item)end end
end
values_only(cache.list(song))
assert(store.write_draft(song,other,nil,seq.new_pattern(6),"repeat",0))
local copied,cp,cb,copy_meta=cache.copy_to_new(song,other,token)
assert(copied.length==3 and cp=="repeat" and cb==12 and copy_meta.recovery_token==token)
assert(#cache.list(song)==2,"occupied scratch remains recoverable")
assert(cache.get(song,other,nil).length==3)
assert(cache.close(song) and cache.get(song,other,nil).length==3)
local create=assert(cache.capture(song,other,nil))
local create_candidate=assert(store.prepare(song,3,dirty,"repeat",12,
  function(token,revision)return token==create.token and revision==create.revision and cache.is_current(song,create)end,create))
assert(store.commit(song,create_candidate))
assert(cache.compare_and_clear(song,create,true))
assert(#cache.list(song)==1 and cache.list(song)[1].token~=token,
  "successful exact copied revision removes only its recovery origin")
local scratch_token=cache.list(song)[1].token
assert(cache.copy_to_new(song,other,scratch_token))
local old=assert(cache.capture(song,other,nil))
assert(cache.put(song,other,nil,seq.new_pattern(7),"repeat",0))
assert(not cache.compare_and_clear(song,old,true))
assert(#cache.list(song)==1,"superseded create preserves recovery origin")
local changed=assert(cache.capture(song,other,nil))
assert(cache.compare_and_clear(song,changed,true))
assert(#cache.list(song)==1,"a later edited revision cannot consume original recovery")
assert(cache.discard(song,scratch_token) and not cache.discard(song,scratch_token))

-- Durable hydration captures the currently verified baseline, not historical evidence.
assert(cache.put(song,instrument,b,dirty,"repeat",24))
assert(cache.release(song))
local hydrated,hp,hb,hm=cache.get(song,instrument,b)
assert(hydrated.length==3 and hp=="repeat" and hb==24 and hm.recovered)
local hydrated_token=hm.token
assert(cache.get(song,instrument,b))
assert(select(4,cache.get(song,instrument,b)).token==hydrated_token)
local compatible=assert(seq.copy_source(committed));compatible.pitch_events[32].accent=true
assert(store.save(song,2,compatible,"play_once",0))
assert(not cache.get(song,instrument,b),"source baseline changes detach even when output remains compatible")
assert(#cache.list(song)==1)

-- A colliding ID never imports or changes the shared durable draft.
local duplicate=phrase(2)
other.phrases={duplicate}
local raw=song.tool_data
assert(not cache.get(song,other,duplicate))
assert(not cache.put(song,other,duplicate,seq.new_pattern(8),"repeat",0))
assert(song.tool_data==raw)
assert(not cache.get(song,other,duplicate))
assert(#cache.list(song)==2,"only object-local collision edits enter recovery")
other.phrases={}
assert(cache.has_volatile(song))
local released,warning=cache.release(song)
assert(released and warning and #cache.list(song)==0 and not cache.has_volatile(song))
assert(cache.get(song,instrument,b),"a fresh session can recover unambiguous durable edits")

-- Failed validation preserves local input but cannot seed an accepted baseline.
local invalid={validate=function()return nil,"unverified"end}
assert(not cache.put(song,instrument,a,dirty,"repeat",0,invalid))
assert(not cache.get(song,instrument,a,invalid))
assert(cache.list(song)[1].reason=="unverified")
local calls=0
local proof={source=committed,settings={output_policy="play_once",pb_range=0},
  baseline={value=1},planning_inputs={value=1}}
local stub={validate=function()calls=calls+1;return proof end}
assert(cache.put(song,instrument,a,dirty,"repeat",0,stub))
proof.baseline.value=2
assert(not cache.get(song,instrument,a,stub))
assert(calls==2,"stub validation is current for every access")

-- False and other invalid existing targets never alias the New Phrase scratch.
assert(cache.put(song,other,nil,seq.new_pattern(9),"repeat",0))
assert(not cache.get(song,other,nil,false) and cache.get(song,other,nil).length==9)
assert(not cache.copy_to_new(song,other,cache.list(song)[1].token,false))
assert(cache.get(song,other,nil).length==9)
for _,target in ipairs({false,0,"phrase"}) do
  assert(not cache.put(song,other,target,seq.new_pattern(10),"repeat",0))
  assert(not cache.get(song,other,target) and not cache.restore(song,other,target))
  assert(not cache.capture(song,other,target) and not cache.clear(song,other,target))
  assert(not cache.is_current(song,{kind="existing",instrument=other,phrase=target,token=1,revision=1}))
  assert(cache.get(song,other,nil).length==9)
end
local original_id=own.id
own.id=function()error("required ID read failed")end
assert(not cache.put(song,instrument,a,dirty,"repeat",0,stub))
own.id=original_id

-- Raw instrument identity keeps session scratches through native reorder/rename.
local old_song=song
local scratch={name="Stable",phrases={}}
local neighbor={name="Neighbor",phrases={}}
song={instruments={scratch,neighbor}}
assert(cache.put(song,scratch,nil,seq.new_pattern(5),"repeat",12))
local scratch_request,scratch_guard=cache.capture(song,scratch,nil)
song.instruments[1]={name="Stable",phrases={}}
assert(not scratch_guard(scratch_request.token,scratch_request.revision),
  "a replacement instrument cannot retain a New request's authority")
song.instruments[1]=scratch
local captured_song=song
song={instruments={scratch,neighbor}}
assert(not cache.is_current(captured_song,scratch_request),"released songs invalidate captured guards")
song=captured_song
assert(scratch_guard(scratch_request.token,scratch_request.revision))
local saved_raw=song.tool_data
neighbor.name="Stable"
local shared,_,_,shared_meta=cache.get(song,scratch,nil)
assert(shared.length==5 and not shared_meta.persistent and shared_meta.warning:find("ambiguous",1,true))
neighbor.name="Neighbor"
song.instruments={neighbor,scratch}
scratch.name="Renamed"
local stable,_,_,stable_meta=cache.get(song,scratch,nil)
assert(stable.length==5 and not stable_meta.persistent and stable_meta.warning)
assert(song.tool_data==saved_raw and #cache.list(song)==0)
assert(not cache.put(song,scratch,nil,seq.new_pattern(6),"repeat",0))
assert(cache.get(song,scratch,nil).length==6 and song.tool_data==saved_raw)
assert(cache.release(song))
assert(not cache.get(song,scratch,nil),"reload cannot reattach an old index/name scratch")
assert(cache.put(song,scratch,nil,seq.new_pattern(7),"repeat",0))
song.instruments[2]={name="Renamed",phrases={}}
assert(not cache.get(song,scratch,nil),"same-index replacement does not preserve object association")
assert(#cache.list(song)==1 and cache.list(song)[1].pattern.length==7)
local volatile={name="Volatile",phrases={}}
song={instruments={volatile}}
local save_draft=store.write_draft
store.write_draft=function()return nil,"not persisted"end
assert(not cache.put(song,volatile,nil,seq.new_pattern(2),"repeat",0))
store.write_draft=save_draft
local sole=assert(cache.detach(song,volatile,nil,"detached volatile draft"))
assert(cache.has_volatile(song) and cache.discard(song,sole))
assert(#cache.list(song)==0 and not cache.has_volatile(song) and not cache.has(song),
  "a detached tombstone has no editable or volatile payload after discard")
song=old_song
print("ACID verified draft baselines and isolated recovery passed")
