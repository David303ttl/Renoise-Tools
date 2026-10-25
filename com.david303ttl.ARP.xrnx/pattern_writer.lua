-- ARP v0.5: sub-line scheduling with protected multi-column regeneration.
local M={}
local engine=require("arp_engine")
local owned=require("ownership")

local function valid_track(song,index)
  local t=song.tracks[index]
  return t and t.type==renoise.Track.TRACK_TYPE_SEQUENCER
end
function M.track_choices()
  local song=renoise.song()
  local labels,indices={},{}
  for i,track in ipairs(song.tracks) do
    if valid_track(song,i) then
      labels[#labels+1]=string.format("%02d: %s",i,track.name)
      indices[#indices+1]=i
    end
  end
  return labels,indices
end

local function read_chords(song,index,pattern)
  local chords={}
  for lineno=1,pattern.number_of_lines do
    local line=pattern.tracks[index]:line(lineno)
    local notes={}
    for col=1,song.tracks[index].visible_note_columns do
      local cell=line.note_columns[col]
      if cell and cell.note_value<=119 then
        notes[#notes+1]=cell.note_value
      end
    end
    if #notes>0 then
      chords[#chords+1]={
        line=lineno,notes=notes
      }
    end
  end
  return chords
end

local function cell_at(track,line,column)
  return track:line(line).note_columns[column]
end

-- Conservative structural signature: prevents index-based ownership from
-- silently following renamed/reordered tracks or patterns. If duplicate
-- track names exist, row identity is ambiguous and regeneration is refused.
local function structure_signature(song)
  local track_parts,seen={},{}
  for i,t in ipairs(song.tracks) do
    local name=t.name or ""
    if seen[name] then return nil,"Duplicate track names: ARP cannot verify track identity" end
    seen[name]=true
    track_parts[#track_parts+1]=string.format("%d:%s",t.type or 0,name)
  end
  local pattern_parts={}
  for i,p in ipairs(song.patterns) do
    pattern_parts[#pattern_parts+1]=string.format("%d:%s",p.number_of_lines,p.name or "")
  end
  return owned.encode_name(table.concat(track_parts,"|")
    .."||"..table.concat(pattern_parts,"|"))
end

function M.generate(source_index,dest_index,division,mode,octaves,gate,dest_instrument_index,mute_source)
  local song=renoise.song()
  if not song then return nil,"Open a song first" end
  if source_index==dest_index then
    return nil,"Source and destination must be different tracks"
  end
  if not valid_track(song,source_index) or not valid_track(song,dest_index) then
    return nil,"Both tracks must be sequencer tracks"
  end
  -- Renoise instruments are song-global. Resolve the output instrument
  -- explicitly rather than inheriting any source chord instrument data.
  dest_instrument_index=dest_instrument_index or song.selected_instrument_index
  if type(dest_instrument_index)~="number"
    or dest_instrument_index%1~=0
    or dest_instrument_index<1
    or dest_instrument_index>#song.instruments
    or dest_instrument_index>255 then
    return nil,"Select a valid destination instrument"
  end
  local dest_instrument_value=dest_instrument_index-1
  local source_track=song.tracks[source_index]
  local fingerprint,identity_error=structure_signature(song)
  if not fingerprint then return nil,identity_error end
  local pattern=song.selected_pattern
  local length=pattern.number_of_lines
  local target=pattern.tracks[dest_index]
  local track=song.tracks[dest_index]
  if target.is_alias then
    return nil,"Destination pattern track is aliased"
  end
  local units,rate_error=engine.rate_subunits(song.transport.lpb,division)
  if not units then return nil,rate_error end
  local chords=read_chords(song,source_index,pattern)
  if #chords==0 then return nil,"No source notes in the selected pattern" end

  local plan,plan_error,note_count,off_count,required_columns
  if units%256==0 then
    -- Preserve v0.4 same-column gate behavior for integral-line rates.
    plan,plan_error,note_count,off_count=engine.plan(
      chords,length,units/256,mode,octaves,gate)
    required_columns=1
    if plan then
      for _,event in ipairs(plan) do event.column=1 end
    end
  else
    if gate==100 then
      plan,plan_error,note_count,off_count,required_columns=
        engine.plan_subline(chords,length,units,mode,octaves,gate)
    else
      plan,plan_error,note_count,off_count,required_columns=
        engine.plan_fractional_release(chords,length,units,mode,octaves,gate)
    end
  end
  if not plan then return nil,plan_error end
  if #plan==0 then return nil,"No ARP events to generate" end
  for _,event in ipairs(plan) do
    if event.kind=="on" then
      event.instrument=dest_instrument_value
    end
  end
  if required_columns>track.max_note_columns then
    return nil,"Selected rate exceeds destination note column capacity"
  end
  if track.visible_note_columns<required_columns then
    return nil,string.format(
      "Rate %s at LPB %d needs %d visible destination note columns "
      .. "(currently %d). Expand Track %02d's note columns before Generate.",
      division,song.transport.lpb,required_columns,
      track.visible_note_columns,dest_index)
  end

  -- No source output is removed until the new event plan and metadata
  -- have passed validation.
  local before_data=song.tool_data
  local records,load_error=owned.load(before_data)
  if not records then return nil,load_error end
  local previous,old_index=owned.find(
    records,song.selected_pattern_index,dest_index)

  -- Explicit manual clearing is a safe reset; otherwise metadata is a
  -- strict lease on exactly the events that the tool generated.
  if previous then
    local empty=true
    for line=1,length do
      for col=1,previous.columns do
        if not cell_at(target,line,col).is_empty then
          empty=false
          break
        end
      end
      if not empty then break end
    end
    if empty then previous=nil end
  end

  if previous then
    if previous.length~=length
      or previous.source~=source_index
      or previous.pattern_name~=fingerprint
      or previous.dest_name~=owned.encode_name(track.name)
      or previous.source_name~=owned.encode_name(song.tracks[source_index].name) then
      return nil,"Previous ARP ownership does not match this pattern or routing"
    end
  end

  local columns=math.max(previous and previous.columns or 1,required_columns)
  local planned={}
  for _,event in ipairs(plan) do
    local key=owned.key(event.line,event.column)
    if planned[key] then
      return nil,"Two events would use the same destination cell"
    end
    planned[key]=event
  end

  -- Preflight the entire active output area, including cells the new
  -- pattern would leave empty. Existing user notes are never claimed.
  local backup={}
  for line=1,length do
    for col=1,columns do
      local key=owned.key(line,col)
      local cell=cell_at(target,line,col)
      local expected=previous and previous.events[key] or nil
      if not owned.matches(cell,expected) then
        return nil,string.format(
          "Destination changed at line %02d column %d; no overwrite",
          line-1,col)
      end
      backup[key]=owned.capture(cell)
    end
  end

  local record={
    pattern=song.selected_pattern_index,
    destination=dest_index,
    source=source_index,
    length=length,columns=required_columns,
    pattern_name=fingerprint,
    dest_name=owned.encode_name(track.name),
    source_name=owned.encode_name(song.tracks[source_index].name),
    events={}
  }
  local previous_delay_visible=track.delay_column_visible
  local previous_source_mute=source_track.mute_state
  song:describe_undo(previous and "ARP: regenerate" or "ARP: generate")
  local ok,err=pcall(function()
    if previous then
      for key in pairs(previous.events) do
        local line,col=key:match("^(%d+):(%d+)$")
        cell_at(target,tonumber(line),tonumber(col)):clear()
      end
    end
    local needs_delay=false
    for _,event in ipairs(plan) do
      local cell=cell_at(target,event.line,event.column)
      cell.note_value=event.note
      if event.kind=="on" then cell.instrument_value=event.instrument end
      if event.delay>0 then
        cell.delay_value=event.delay
        needs_delay=true
      end
      record.events[owned.key(event.line,event.column)]=owned.capture(cell)
    end
    if old_index then records[old_index]=record
    else records[#records+1]=record end
    song.tool_data=owned.save(records)
    if needs_delay then track.delay_column_visible=true end
    -- A mixer MUTE silences only the source track's audio. With a plugin
    -- routed to another track, the source notes would still be triggered.
    -- Explicit OFF suppresses *new note and effect triggers*, regardless
    -- of the user's global Renoise mute preference. Existing chord
    -- data is unchanged and remains readable by this Lua tool.
    -- Perform this only after successfully writing output.
    if mute_source
      and source_track.mute_state~=renoise.Track.MUTE_STATE_OFF then
      source_track.mute_state=renoise.Track.MUTE_STATE_OFF
    end
  end)
  if not ok then
    local rollback_ok,rollback_err=pcall(function()
      for line=1,length do
        for col=1,columns do
          local key=owned.key(line,col)
          owned.restore(cell_at(target,line,col),backup[key])
        end
      end
      song.tool_data=before_data
      track.delay_column_visible=previous_delay_visible
      if source_track.mute_state~=previous_source_mute then
        source_track.mute_state=previous_source_mute
      end
    end)
    if not rollback_ok then
      return nil,"Write and rollback failed: "..tostring(rollback_err)
    end
    return nil,"Generation failed; old data restored: "..tostring(err)
  end
  return {
    action=previous and "Regenerated" or "Generated",
    notes=note_count,offs=off_count,columns=required_columns,
    instrument=dest_instrument_value,
    source_off=source_track.mute_state==renoise.Track.MUTE_STATE_OFF
  }
end
return M
