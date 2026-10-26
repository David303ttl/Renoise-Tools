dofile('tests/bootstrap.lua')('arp')
-- Run: luatex --luaonly tests/arp/arp_v04_spec.lua
-- Or: lua tests/arp/arp_v04_spec.lua
local engine=require("arp_engine")
local owned=require("ownership")
local writer=require("pattern_writer")

local chord={{line=1, notes={60,64,67}, instrument=0}}
local events,err,ons,offs=engine.plan(chord,16,4,"up",1,50)
assert(events and not err and ons==4 and offs==4)
assert(events[1].line==1 and events[1].note==60)
assert(events[2].line==3 and events[2].note==120)
assert(events[3].line==5 and events[3].note==64)
local half=assert(engine.plan(chord,16,2,"up",1,75))
assert(half[2].line==2 and half[2].delay==128)
local rejected,why=engine.plan(chord,16,1,"up",1,50)
assert(not rejected and why:find("same line"))
local overlap,overlaperr=engine.plan({
  {line=1,notes={60},instrument=0},
  {line=2,notes={64},instrument=0}
},16,4,"up",1,75)
assert(not overlap and overlaperr:find("overlaps"))
local boundary,boundaryerr=engine.plan(
  {{line=16,notes={60},instrument=0}},16,4,"up",1,50)
assert(not boundary and boundaryerr:find("pattern end"))
assert(engine.plan(chord,16,1,"up",1,100))

local function new_cell()
  local c={}
  local function clear(t)
    t.note_value=121
    t.instrument_value=255
    t.volume_value=255
    t.panning_value=255
    t.delay_value=0
    t.effect_number_value=0
    t.effect_amount_value=0
  end
  function c:clear() clear(self) end
  setmetatable(c,{
    __index=function(t,k)
      if k=="is_empty" then
        return t.note_value==121 and t.instrument_value==255
          and t.volume_value==255 and t.panning_value==255
          and t.delay_value==0 and t.effect_number_value==0
          and t.effect_amount_value==0
      end
    end
  })
  c:clear()
  return c
end

local function new_pattern_track(lines)
  local data={}
  for i=1,lines do
    data[i]={note_columns={new_cell(),new_cell()}}
  end
  return {
    is_alias=false,
    line=function(self,i) return data[i] end
  }
end

local current_song
renoise={
  Track={TRACK_TYPE_SEQUENCER=1,MUTE_STATE_ACTIVE=1,MUTE_STATE_MUTED=2,MUTE_STATE_OFF=3},
  song=function() return current_song end
}
local function make_song(lines)
  local pattern={
    name="Pattern A",number_of_lines=lines,
    tracks={new_pattern_track(lines),new_pattern_track(lines)}
  }
  local song={
    tracks={
      {type=1,name="Source",visible_note_columns=2,max_note_columns=12,
       delay_column_visible=false,mute_state=1,
       mute=function(self) self.mute_state=2 end},
      {type=1,name="Dest",visible_note_columns=2,max_note_columns=12,delay_column_visible=false,
       mute_state=1,mute=function(self) self.mute_state=2 end}
    },
    transport={lpb=4}, patterns={pattern}, selected_pattern=pattern,
    selected_pattern_index=1,selected_instrument_index=1,
    instruments={{name="A"},{name="B"}},tool_data=nil,
    describe_undo=function(self,msg) self.undo_description=msg end
  }
  return song
end

current_song=make_song(16)
local src=current_song.selected_pattern.tracks[1]
local dst=current_song.selected_pattern.tracks[2]
src:line(1).note_columns[1].note_value=60
src:line(1).note_columns[1].instrument_value=0
src:line(1).note_columns[2].note_value=64
local first,first_err=writer.generate(1,2,"1/4","up",1,50)
assert(first,first_err)
assert(first.action=="Generated" and first.notes==4 and first.offs==4)
assert(dst:line(1).note_columns[1].note_value==60)
assert(dst:line(3).note_columns[1].note_value==120)
assert(dst:line(5).note_columns[1].note_value==64)
assert(current_song.tool_data:find("ARP05",1,true)==1)
local data=current_song.tool_data
local registry,parse_err=owned.load(data)
assert(registry,parse_err)
assert(#registry==1)
assert(owned.save(registry)==data)
local bad_registry,bad_error=owned.load("unknown")
assert(not bad_registry and bad_error)

-- Unowned column 2 survives regeneration.
dst:line(4).note_columns[2].note_value=74
local replacement,replacement_err=writer.generate(1,2,"1/8","down",2,50)
assert(replacement,replacement_err)
assert(replacement.action=="Regenerated")
assert(replacement.offs==8 and replacement.notes==8)
assert(dst:line(4).note_columns[2].note_value==74)
assert(dst:line(2).note_columns[1].note_value==120)
assert(dst:line(16).note_columns[1].note_value==120)
-- An owned note edit must refuse without changing any cells or metadata.
dst:line(1).note_columns[1].note_value=30
local before=current_song.tool_data
local mismatch,message=writer.generate(1,2,"1/4","up",1,50)
assert(not mismatch and message:find("changed"))
assert(dst:line(1).note_columns[1].note_value==30)
assert(current_song.tool_data==before)

-- Even with missing metadata an existing destination is never touched.
current_song.tool_data=nil
local again,again_err=writer.generate(1,2,"1/4","up",1,50)
assert(not again and again_err:find("changed"))
assert(dst:line(1).note_columns[1].note_value==30)

-- Explicit unrepresentable gate leaves entire target unchanged.
current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
dst=current_song.selected_pattern.tracks[2]
src:line(1).note_columns[1].note_value=60
local unsupported,msg=writer.generate(1,2,"1/16","up",1,50)
assert(not unsupported and msg:find("same line"))
assert(dst:line(1).note_columns[1].is_empty)
assert(current_song.tool_data==nil)

-- Manual clearing of all owned destination events should allow a fresh
-- generation, even if XRNS still contains stale ownership metadata.
current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
dst=current_song.selected_pattern.tracks[2]
src:line(1).note_columns[1].note_value=60
local initial,initial_err=writer.generate(1,2,"1/4","up",1,50)
assert(initial,initial_err)
for i=1,16 do dst:line(i).note_columns[1]:clear() end
local recovery,recovery_err=writer.generate(1,2,"1/4","up",1,50)
assert(recovery,recovery_err)
assert(recovery.action=="Generated")
assert(dst:line(1).note_columns[1].note_value==60)

-- With stale ownership AND a real, unowned note, refuse without erasing.
for i=1,16 do dst:line(i).note_columns[1]:clear() end
dst:line(1).note_columns[1].note_value=72
local declined,decline_err=writer.generate(1,2,"1/4","up",1,50)
assert(not declined and decline_err:find("changed"))
assert(dst:line(1).note_columns[1].note_value==72)


-- v0.5 fractional-rate scheduling, including multiple columns per line.
assert(engine.rate_subunits(4,"1/32")==128)
assert(engine.rate_subunits(1,"1/32")==32)
assert(engine.rate_subunits(3,"1/8")==384)
local fractional,fractional_err,nc,oc,cols=engine.plan_subline(
  {{line=1,notes={60,64},instrument=0}},2,128,"up",1,100)
assert(fractional,fractional_err)
assert(nc==4 and oc==0 and cols==2)
assert(fractional[1].line==1 and fractional[1].column==1
  and fractional[1].delay==0 and fractional[1].note==60)
assert(fractional[2].line==1 and fractional[2].column==2
  and fractional[2].delay==128 and fractional[2].note==64)
assert(fractional[3].line==2 and fractional[3].column==1)
local too_short,short_err=engine.plan_subline(
  {{line=1,notes={60},instrument=0}},4,128,"up",1,50)
assert(not too_short and short_err:find("100%%"))

current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
dst=current_song.selected_pattern.tracks[2]
src:line(1).note_columns[1].note_value=60
src:line(1).note_columns[1].instrument_value=0
src:line(1).note_columns[2].note_value=64
local sub_result,sub_error=writer.generate(1,2,"1/32","up",1,100)
assert(sub_result,sub_error)
assert(sub_result.notes==32 and sub_result.columns==2)
assert(dst:line(1).note_columns[1].note_value==60)
assert(dst:line(1).note_columns[2].note_value==64)
assert(dst:line(1).note_columns[2].delay_value==128)
assert(current_song.tracks[2].delay_column_visible==true)
local fractional_meta=current_song.tool_data
local parsed,parse_error=owned.load(fractional_meta)
assert(parsed,parse_error)
assert(parsed[1].columns==2)
assert(owned.save(parsed)==fractional_meta)

-- A changing rate can free its previously generated second column safely.
local slower,slower_error=writer.generate(1,2,"1/4","up",1,50)
assert(slower,slower_error)
assert(slower.action=="Regenerated" and slower.columns==1)
assert(dst:line(1).note_columns[2].is_empty)
assert(dst:line(3).note_columns[1].note_value==120)
assert(dst:line(1).note_columns[1].note_value==60)

-- Any unowned note in a needed second column blocks regeneration.
dst:line(1).note_columns[2].note_value=79
local prevented,prevented_err=writer.generate(1,2,"1/32","up",1,100)
assert(not prevented and prevented_err:find("column 2"))
assert(dst:line(1).note_columns[2].note_value==79)

-- A 1/32 note with Gate 50% cannot be represented and must not mutate.
local unsupported_sub,unsupported_sub_err=writer.generate(
  1,2,"1/32","up",1,50)
assert(not unsupported_sub and unsupported_sub_err:find("100%%"))
assert(dst:line(1).note_columns[1].note_value==60)

-- More demanding rates require a suitably configured destination.
current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
src:line(1).note_columns[1].note_value=60
current_song.tracks[2].visible_note_columns=1
local missing_cols,columns_err=writer.generate(1,2,"1/32","up",1,100)
assert(not missing_cols and columns_err:find("2 visible"))
assert(current_song.selected_pattern.tracks[2]:line(1).note_columns[1].is_empty)

-- Legacy v0.4 ownership loads into v0.5 keyed snapshot records.
local old="ARP04\nR|1|2|1|16|41|42|43|1,60,0,255,255,0,0,0\n"
local migrated,migration_error=owned.load(old)
assert(migrated,migration_error)
assert(migrated[1].columns==1)
assert(migrated[1].events[owned.key(1,1)][1]==60)
assert(owned.save(migrated):find("ARP05",1,true)==1)


-- Instrument routing must override source cell instrument regardless of
-- which instrument was used to enter the chord.
current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
dst=current_song.selected_pattern.tracks[2]
src:line(1).note_columns[1].note_value=60
src:line(1).note_columns[1].instrument_value=0
local routed,routed_err=writer.generate(1,2,"1/4","up",1,100,2,true)
assert(routed,routed_err)
assert(dst:line(1).note_columns[1].instrument_value==1)
assert(src:line(1).note_columns[1].instrument_value==0)
assert(current_song.tracks[1].mute_state==3)
local second,second_err=writer.generate(1,2,"1/8","up",1,100,1,false)
assert(second,second_err)
assert(dst:line(1).note_columns[1].instrument_value==0)
assert(current_song.tracks[1].mute_state==3) -- no implicit unmute
local invalid,invalid_err=writer.generate(1,2,"1/4","up",1,100,99,true)
assert(not invalid and invalid_err:find("valid destination instrument"))


-- Tick-cut planner validation (not yet part of the Renoise renderer).
local cut_plan=assert(engine.plan_subline(
  {{line=1,notes={60},instrument=0}},4,128,"up",1,100))
local cut,cut_error=engine.attach_tick_cuts(cut_plan,128,50,12)
assert(cut,cut_error)
assert(cut[1].cut_ticks==3)
assert(engine.cut_command_value(3)==0x4333)
local rounded,rounded_err=engine.attach_tick_cuts(cut_plan,128,25,12)
assert(not rounded and rounded_err:find("exact integer"))
local crosses,cross_err=engine.attach_tick_cuts(
  {{line=1,delay=128,note=60,column=1}},256,75,8)
assert(not crosses and cross_err:find("line boundary"))


-- Even a previously MIXER-MUTED source must become OFF, not just muted.
current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
src:line(1).note_columns[1].note_value=60
current_song.tracks[1].mute_state=renoise.Track.MUTE_STATE_MUTED
local routed_off,routed_off_err=writer.generate(1,2,"1/4","up",1,100,2,true)
assert(routed_off,routed_off_err)
assert(current_song.tracks[1].mute_state==renoise.Track.MUTE_STATE_OFF)
-- On refusal, existing source track state must remain unchanged.
current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
src:line(1).note_columns[1].note_value=60
local rejected_off,rejected_off_err=writer.generate(1,2,"1/16","up",1,25,2,true)
assert(not rejected_off)
assert(current_song.tracks[1].mute_state==renoise.Track.MUTE_STATE_ACTIVE)


-- v0.7 fractional release events: exactly representable 1/32 at LPB 4,
-- Gate 50% needs a same-line OFF and must reject. A fractional 1/8
-- at LPB 3 and Gate 75% can create a delayed next-line OFF.
local fractional_ok,fe,n_on,n_off,ncols=engine.plan_fractional_release(
  {{line=1,notes={60,64},instrument=0}},9,384,"up",1,75)
assert(fractional_ok,fe)
assert(n_on==6 and n_off==6 and ncols>=1)
assert(fractional_ok[1].kind=="on" and fractional_ok[2].kind=="off")
local fractional_no,fr_err=engine.plan_fractional_release(
  {{line=1,notes={60},instrument=0}},8,128,"up",1,50)
assert(not fractional_no and fr_err:find("shares a pattern line"))
-- Renaming a different track invalidates ownership without changing output.
current_song=make_song(16)
src=current_song.selected_pattern.tracks[1]
src:line(1).note_columns[1].note_value=60
local created,created_err=writer.generate(1,2,"1/4","up",1,100,1,false)
assert(created,created_err)
current_song.tracks[1].name="Renamed source"
local structural,structural_err=writer.generate(1,2,"1/4","up",1,100,1,false)
assert(not structural and structural_err:find("ownership"))
assert(current_song.selected_pattern.tracks[2]:line(1).note_columns[1].note_value==60)

print("ARP gates, ownership, routing and cut planning tests passed")
