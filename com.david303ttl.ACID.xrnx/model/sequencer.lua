-- SPDX-License-Identifier: GPL-3.0-only
-- ACID pitch/time memory. Drafts can be partially entered.
-- Pitch and time memories have independent contents and 32-slot capacity.
local policies = require("model.policies")
local M = {}
M.MAX_STEPS = 32
M.PAGE_SIZE = 16
M.BASE_NOTE = 36 -- C-3 in Renoise
local SOURCE_FIELDS={length=true,pitch_length=true,timing_mode=true,pitch_events=true,time_events=true,
  scale_mask_enabled=true,scale_mask=true}
local prepared_records=setmetatable({},{__mode="k"})

local integer_between = policies.in_integer_range

local function array_size(a)
  if type(a) ~= "table" then return nil end
  local n, max = 0, 0
  for key in pairs(a) do
    if not integer_between(key, 1, M.MAX_STEPS) then return nil end
    n = n + 1
    if key > max then max = key end
  end
  if n ~= max then return nil end
  return n
end

function M.new_pattern(length,...)
  assert(select("#",...)==0,"new_pattern accepts only LAST STEP")
  length = length or M.PAGE_SIZE
  assert(integer_between(length, 1, M.MAX_STEPS), "length must be 1..32")
  -- PITCH and TIME memories are fixed-capacity; LAST STEP selects the active
  -- TIME prefix. Untouched PITCH positions play C with no ACCENT or SLIDE.
  local pitches = {}
  for i=1,M.MAX_STEPS do
    pitches[i] = M.new_pitch(0,0,false,false)
  end
  local time_events = {}
  for i=1,M.MAX_STEPS do time_events[i] = "N" end
  local mask={}
  for i=1,12 do mask[i]=true end
  return {length=length, pitch_length=M.PAGE_SIZE, timing_mode="straight", pitch_events=pitches,
    time_events=time_events,scale_mask_enabled=false,scale_mask=mask}
end

function M.set_pitch_length(pattern, pitch_length)
  if type(pattern) ~= "table" or
      not integer_between(pitch_length, 1, M.MAX_STEPS) then
    return false, "pitch length must be 1..32"
  end
  pattern.pitch_length = pitch_length
  return true
end

function M.is_leading_tie(step, command)
  return step == 1 and command == "T"
end

function M.normalize_time_entry(step, command)
  if not integer_between(step, 1, M.MAX_STEPS) then return nil, "invalid time step" end
  if command ~= "N" and command ~= "T" and command ~= "R" then
    return nil, "invalid timing command"
  end
  return M.is_leading_tie(step, command) and "N" or command
end

function M.set_time(pattern, step, command)
  if type(pattern) ~= "table" or not integer_between(pattern.length, 1, M.MAX_STEPS)
    or type(pattern.time_events)~="table" then
    return nil, "invalid pattern"
  end
  if not integer_between(step, 1, pattern.length) then
    return nil, "invalid time step"
  end
  local normalized, err = M.normalize_time_entry(step, command)
  if not normalized then return nil, err end
  command = normalized
  pattern.time_events[step] = command
  return command
end

-- Original 13-key pitch keyboard, combined with octave DOWN/NORMAL/UP.
function M.new_pitch(key, octave, accent, slide)
  assert(integer_between(key, 0, 12), "keyboard key must be 0..12")
  assert(integer_between(octave, -1, 1), "octave must be -1, 0 or +1")
  assert(accent==nil or type(accent)=="boolean", "accent must be boolean")
  assert(slide==nil or type(slide)=="boolean", "slide must be boolean")
  return {note=M.BASE_NOTE+key+octave*12, key=key, octave=octave,
    accent=accent==true, slide=slide==true}
end

function M.pitch_controls(p)
  if type(p) ~= "table" or not integer_between(p.note, 24, 60) then
    return nil, "invalid pitch"
  end
  if not integer_between(p.key, 0, 12) or
    not integer_between(p.octave, -1, 1) or
    p.note ~= M.BASE_NOTE+p.key+p.octave*12 then
    return nil, "pitch keyboard/octave does not match MIDI note"
  end
  return p.key, p.octave
end

function M.validate(pattern)
  if type(pattern) ~= "table" then return false, "pattern must be a table" end
  for key in pairs(pattern) do
    if not SOURCE_FIELDS[key] then return false,"unknown source field: "..tostring(key) end
  end
  if not integer_between(pattern.length, 1, M.MAX_STEPS) then
    return false, "pattern length must be 1..32"
  end
  if not integer_between(pattern.pitch_length, 1, M.MAX_STEPS) then
    return false, "pitch length must be 1..32"
  end
  if pattern.timing_mode ~= "straight" and pattern.timing_mode ~= "triplet" then
    return false, "timing mode must be straight or triplet"
  end
  if type(pattern.scale_mask_enabled)~="boolean" then
    return false,"scale mask enabled state must be boolean"
  end
  if type(pattern.scale_mask)~="table" then return false,"scale mask must be a dense 12-element array" end
  local mask_count,mask_max=0,0
  for key,value in pairs(pattern.scale_mask) do
    if not integer_between(key,1,12) then return false,"scale mask must be a dense 12-element array" end
    if type(value)~="boolean" then return false,"scale mask entries must be boolean" end
    mask_count=mask_count+1
    if key>mask_max then mask_max=key end
  end
  if mask_count~=12 or mask_max~=12 then return false,"scale mask must be a dense 12-element array" end
  if pattern.scale_mask_enabled then
    local any=false
    for i=1,12 do any=any or pattern.scale_mask[i] end
    if not any then return false,"enabled scale mask must allow at least one pitch class" end
  end
  if array_size(pattern.pitch_events) ~= M.MAX_STEPS then
    return false, "PITCH memory must contain exactly 32 entries"
  end
  local np, nt = array_size(pattern.pitch_events), array_size(pattern.time_events)
  if np == nil or nt == nil then
    return false, "pitch_events and time_events must be dense arrays (maximum 32 entries)"
  end
  if nt ~= M.MAX_STEPS then
    return false, "TIME memory must contain exactly 32 entries"
  end
  for i, p in ipairs(pattern.pitch_events) do
    if type(p) ~= "table" or not integer_between(p.note, 24, 60) then
      return false, "invalid pitch at entry " .. i
    end
    for key in pairs(p) do
      if key~="note" and key~="key" and key~="octave" and
          key~="accent" and key~="slide" then
        return false,"unknown pitch field at entry "..i..": "..tostring(key)
      end
    end
    local key, octave_or_error = M.pitch_controls(p)
    if key == nil then
      return false, octave_or_error .. " at pitch entry " .. i
    end
    if type(p.accent) ~= "boolean" then
      return false, "accent must be boolean at entry " .. i
    end
    if type(p.slide) ~= "boolean" then
      return false, "slide must be boolean at entry " .. i
    end
  end
  for i, t in ipairs(pattern.time_events) do
    if t ~= "N" and t ~= "T" and t ~= "R" then
      return false, "invalid timing command at step " .. i
    end
  end
  if M.is_leading_tie(1, pattern.time_events[1]) then
    return false, "leading TIE must be entered as NOTE"
  end
  return true
end

function M.copy_source(pattern)
  local valid,err=M.validate(pattern)
  if not valid then return nil,err end
  local copy={length=pattern.length,pitch_length=pattern.pitch_length,
    timing_mode=pattern.timing_mode,pitch_events={},time_events={},
    scale_mask_enabled=pattern.scale_mask_enabled,scale_mask={}}
  for i=1,12 do copy.scale_mask[i]=pattern.scale_mask[i] end
  for i=1,M.MAX_STEPS do
    local pitch=pattern.pitch_events[i]
    copy.pitch_events[i]={note=pitch.note,key=pitch.key,octave=pitch.octave,
      accent=pitch.accent,slide=pitch.slide}
    copy.time_events[i]=pattern.time_events[i]
  end
  return copy
end

function M.same_source(a,b)
  if not M.validate(a) or not M.validate(b) then return false end
  if a.length~=b.length or a.pitch_length~=b.pitch_length or
      a.timing_mode~=b.timing_mode or a.scale_mask_enabled~=b.scale_mask_enabled then return false end
  for i=1,12 do if a.scale_mask[i]~=b.scale_mask[i] then return false end end
  for i=1,M.MAX_STEPS do
    local x,y=a.pitch_events[i],b.pitch_events[i]
    if x.note~=y.note or x.key~=y.key or x.octave~=y.octave or
        x.accent~=y.accent or x.slide~=y.slide or
        a.time_events[i]~=b.time_events[i] then return false end
  end
  return true
end

local CLIPBOARD_FIELDS={
  pitch={pitch_events=true,pitch_length=true},
  time={time_events=true,length=true},
  both={pitch_events=true,pitch_length=true,time_events=true,length=true}}

function M.make_clipboard(source,scope)
  local fields=CLIPBOARD_FIELDS[scope]
  if not fields then return nil,"invalid clipboard scope" end
  local detached,err=M.copy_source(source)
  if not detached then return nil,err end
  local payload={}
  for field in pairs(fields) do payload[field]=detached[field] end
  return payload
end

function M.paste_candidate(source,payload,scope)
  local fields=CLIPBOARD_FIELDS[scope]
  if not fields then return nil,"invalid clipboard scope" end
  if type(payload)~="table" or getmetatable(payload)~=nil then
    return nil,"clipboard payload must be a plain table"
  end
  for field in pairs(payload) do
    if not fields[field] then return nil,"unexpected clipboard field: "..tostring(field) end
  end
  local candidate,err=M.copy_source(source)
  if not candidate then return nil,err end
  for field in pairs(fields) do
    if payload[field]==nil then return nil,"missing clipboard field: "..field end
    if type(payload[field])=="table" and getmetatable(payload[field])~=nil then
      return nil,"clipboard arrays must be plain tables"
    end
    candidate[field]=payload[field]
  end
  if fields.pitch_events and type(payload.pitch_events)=="table" then
    for _,pitch in pairs(payload.pitch_events) do
      if type(pitch)=="table" and getmetatable(pitch)~=nil then
        return nil,"clipboard pitches must be plain tables"
      end
    end
  end
  return M.copy_source(candidate)
end

local function canonical_pitch(note)
  if note==60 then return {note=60,key=12,octave=1} end
  return {note=note,key=note%12,octave=math.floor((note-M.BASE_NOTE)/12)}
end

function M.mask_candidate(source,enabled,bits)
  local candidate,err=M.copy_source(source)
  if not candidate then return nil,err end
  candidate.scale_mask_enabled=enabled
  candidate.scale_mask=bits
  return M.copy_source(candidate)
end
local RNG_MODULUS=2147483647
local RNG_MULTIPLIER=16807
local RNG_MAX_SEED=RNG_MODULUS-1
local MIN_NOTE,MAX_NOTE=24,60
local MAX_WEIGHT=1000
local OPERATIONS={clear_pitch="pitch",clear_time="time",clear_tie="time",
  clear_rest="time",clear_slide="pitch",clear_accent="pitch",
  rest_to_note="time",tie_to_rest="time",randomize_pitch="pitch",randomize_time="time"}

function M.random_choice(state,count)
  if not integer_between(state,1,RNG_MAX_SEED) or
      not integer_between(count,1,MAX_WEIGHT*3) then return nil,"invalid random choice" end
  state=(state*RNG_MULTIPLIER)%RNG_MODULUS
  return math.floor((state-1)*count/RNG_MAX_SEED),state
end

function M.operation_candidate(source,operation,scope,parameters)
  local memory=OPERATIONS[operation]
  if not memory then return nil,"invalid source operation" end
  if scope~="active" and scope~="all" then return nil,"invalid operation scope" end
  local candidate,err=M.copy_source(source)
  if not candidate then return nil,err end
  local randomize=operation=="randomize_pitch" or operation=="randomize_time"
  local state,count
  if randomize then
    if type(parameters)~="table" or not integer_between(parameters.seed,1,RNG_MAX_SEED) then
      return nil,"seed must be 1..2147483646"
    end
    state=parameters.seed
    if memory=="pitch" then
      if not integer_between(parameters.min_note,MIN_NOTE,MAX_NOTE) or
          not integer_between(parameters.max_note,MIN_NOTE,MAX_NOTE) or
          parameters.min_note>parameters.max_note then return nil,"invalid pitch range" end
      count=parameters.max_note-parameters.min_note+1
    else
      for _,field in ipairs({"note_weight","tie_weight","rest_weight"}) do
        if not integer_between(parameters[field],0,MAX_WEIGHT) then return nil,"invalid TIME weight" end
      end
      count=parameters.note_weight+parameters.tie_weight+parameters.rest_weight
      if count==0 then return nil,"TIME weights must have a positive sum" end
    end
  end
  local bound=scope=="all" and M.MAX_STEPS or
    (memory=="pitch" and source.pitch_length or source.length)
  for index=1,bound do
    local pitch=candidate.pitch_events[index]
    local command=candidate.time_events[index]
    if operation=="clear_pitch" then candidate.pitch_events[index]=M.new_pitch(0,0,false,false)
    elseif operation=="clear_slide" then pitch.slide=false
    elseif operation=="clear_accent" then pitch.accent=false
    elseif operation=="clear_time" then command="N"
    elseif operation=="clear_tie" and command=="T" then command="N"
    elseif (operation=="clear_rest" or operation=="rest_to_note") and command=="R" then command="N"
    elseif operation=="tie_to_rest" and command=="T" then command="R"
    elseif randomize then
      local bucket
      bucket,state=M.random_choice(state,count)
      if memory=="pitch" then
        local sampled=canonical_pitch(parameters.min_note+bucket)
        sampled.accent,sampled.slide=pitch.accent,pitch.slide
        candidate.pitch_events[index]=sampled
      elseif bucket<parameters.note_weight then command="N"
      elseif bucket<parameters.note_weight+parameters.tie_weight then command="T"
      else command="R" end
    end
    if memory=="time" then
      candidate.time_events[index]=assert(M.normalize_time_entry(index,command))
    end
  end
  local valid,validation_error=M.validate(candidate)
  if not valid then return nil,validation_error end
  return candidate
end
function M.resolve_pitches(source)
  local valid,err=M.validate(source)
  if not valid then return nil,err end
  local resolved={}
  for i=1,M.MAX_STEPS do
    local raw=source.pitch_events[i]
    local note=raw.note
    if source.scale_mask_enabled then
      local best_distance=math.huge
      for candidate=24,60 do
        local pitch_class=candidate%12+1
        if source.scale_mask[pitch_class] then
          local distance=math.abs(candidate-raw.note)
          if distance<best_distance then note,best_distance=candidate,distance end
        end
      end
    end
    resolved[i]=canonical_pitch(note)
  end
  return resolved
end

local function same_records(a,b)
  if type(a)~="table" or type(b)~="table" then return false end
  for key in pairs(a) do
    if type(key)~="number" or key<1 or key>32 or key%1~=0 then return false end
  end
  for key in pairs(b) do
    if type(key)~="number" or key<1 or key>32 or key%1~=0 then return false end
  end
  for i=1,32 do
    local x,y=a[i],b[i]
    if type(x)~="table" or type(y)~="table" or x.note~=y.note or x.key~=y.key or x.octave~=y.octave then return false end
    for key in pairs(x) do if key~="note" and key~="key" and key~="octave" then return false end end
  end
  return true
end

function M.prepare_resolution(source)
  local frozen,err=M.copy_source(source)
  if not frozen then return nil,err end
  local records,resolve_error=M.resolve_pitches(frozen)
  if not records then return nil,resolve_error end
  local bundle={source=frozen,resolved_records=records}
  local private_records={}
  for i=1,M.MAX_STEPS do
    local pitch=records[i]
    private_records[i]={note=pitch.note,key=pitch.key,octave=pitch.octave}
  end
  local provenance={}
  prepared_records[provenance]={source=assert(M.copy_source(frozen)),records=private_records}
  bundle.provenance=provenance
  return bundle
end

function M.validate_prepared(prepared,source)
  if type(prepared)~="table" or getmetatable(prepared)~=nil or
      type(prepared.provenance)~="table" then return nil,"invalid prepared pitch resolution" end
  local private=prepared_records[prepared.provenance]
  if not private or not M.same_source(prepared.source,private.source) or
      not same_records(prepared.resolved_records,private.records) then
    return nil,"prepared pitch resolution was changed or forged"
  end
  if source and not M.same_source(source,private.source) then
    return nil,"prepared pitch resolution does not match source"
  end
  return true
end

function M.detach_prepared(prepared,source)
  local valid,err=M.validate_prepared(prepared,source)
  if not valid then return nil,err end
  local detached_source=assert(M.copy_source(prepared.source))
  local records={}
  for i=1,32 do
    local pitch=prepared.resolved_records[i]
    records[i]={note=pitch.note,key=pitch.key,octave=pitch.octave}
  end
  local detached={source=detached_source,resolved_records=records,provenance=prepared.provenance}
  return detached
end

return M
