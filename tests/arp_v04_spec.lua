-- Run: luatex --luaonly tests/arp_v04_spec.lua
-- Or: lua tests/arp_v04_spec.lua
package.path="com.david303ttl.ARP.xrnx/?.lua;"..package.path
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
  Track={TRACK_TYPE_SEQUENCER=1},
  song=function() return current_song end
}
local function make_song(lines)
  local pattern={
    name="Pattern A",number_of_lines=lines,
    tracks={new_pattern_track(lines),new_pattern_track(lines)}
  }
  local song={
    tracks={
      {type=1,name="Source",visible_note_columns=2},
      {type=1,name="Dest",visible_note_columns=2}
    },
    transport={lpb=4}, selected_pattern=pattern,
    selected_pattern_index=1,selected_instrument_index=1,
    tool_data=nil,
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
assert(current_song.tool_data:find("ARP04",1,true)==1)
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

print("ARP v0.4 gate, ownership and regeneration tests passed")
