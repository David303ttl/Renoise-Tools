-- SPDX-License-Identifier: GPL-3.0-only
-- Song-persistent drafts with detached session cache for active editor objects.
local sequencer = require("model.sequencer")
local store = require("model.pattern_store")
local ownership = require("writers.phrase_ownership")
local M = {}

local NEW_PHRASE = {}
local drafts = setmetatable({}, {__mode = "k"})
local POLICIES = { ["repeat"] = true, play_once = true }
local PB_RANGES = {[0]=true,[2]=true,[12]=true,[24]=true,[48]=true}

local function valid_pb_range(value)
  return type(value)=="number" and value%1==0 and PB_RANGES[value]
end

local function clone_pattern(pattern)
  local copy = {
    length = pattern.length,
    pitch_length = pattern.pitch_length,
    timing_mode = pattern.timing_mode,
    pitch_events = {},
    time_events = {}
  }
  for i = 1, sequencer.MAX_STEPS do
    local pitch = pattern.pitch_events[i]
    copy.pitch_events[i] = {
      note = pitch.note,
      key = pitch.key,
      octave = pitch.octave,
      accent = pitch.accent,
      slide = pitch.slide
    }
    copy.time_events[i] = pattern.time_events[i]
  end
  return copy
end

local function bucket(song, instrument, phrase, create)
  if song == nil or instrument == nil then return nil end
  local by_instrument = drafts[song]
  if not by_instrument and create then
    by_instrument = setmetatable({}, {__mode = "k"})
    drafts[song] = by_instrument
  end
  if not by_instrument then return nil end
  local by_phrase = by_instrument[instrument]
  if not by_phrase and create then
    by_phrase = {}
    by_instrument[instrument] = by_phrase
  end
  if not by_phrase then return nil end
  return by_phrase, phrase or NEW_PHRASE
end

local function instrument_index(song,instrument)
  for index,candidate in ipairs(song.instruments or {}) do
    if rawequal(candidate,instrument) then return index end
  end
end

local function phrase_id(phrase)
  if not phrase or ownership.status(phrase)~="owned" then return 0 end
  local id=ownership.id(phrase)
  if type(id)~="number" or id%1~=0 or id<1 then return 0 end
  return id
end

local function phrase_belongs(instrument,phrase)
  if not phrase or type(instrument.phrases)~="table" then return true end
  for _,candidate in ipairs(instrument.phrases) do
    if rawequal(candidate,phrase) then return true end
  end
  return false
end

function M.put(song, instrument, phrase, pattern, output_policy, pb_range)
  if song == nil or instrument == nil then return nil, "song and instrument are required" end
  if not phrase_belongs(instrument,phrase) then return nil,"draft phrase is no longer in the selected instrument" end
  if type(pattern) ~= "table" then return nil, "draft source is required" end
  local valid, err = sequencer.validate(pattern)
  if not valid then return nil, err end
  output_policy = output_policy or "repeat"
  if not POLICIES[output_policy] then return nil, "invalid phrase output policy" end
  pb_range=pb_range==nil and 0 or pb_range
  if not valid_pb_range(pb_range) then return nil,"invalid PB range" end
  local by_phrase, key = bucket(song, instrument, phrase, true)
  by_phrase[key] = {pattern = clone_pattern(pattern), output_policy = output_policy,
    pb_range=pb_range,
    persistent=false}
  local index=instrument_index(song,instrument)
  if not index then return nil,"draft instrument is no longer in this song" end
  if phrase and phrase_id(phrase)==0 then
    return nil,"draft phrase has no current ACID identity; it remains only in this editor session"
  end
  if not phrase then
    local name=tostring(instrument.name or "")
    local matches=0
    for _,candidate in ipairs(song.instruments or {}) do
      if tostring(candidate.name or "")==name then matches=matches+1 end
    end
    if matches~=1 then return nil,"new phrase draft destination is ambiguous; select it again after reopening" end
  end
  local saved,save_error=store.write_draft(song,index,phrase_id(phrase),instrument.name,
    pattern,output_policy,pb_range)
  if not saved then return nil,save_error end
  by_phrase[key].persistent=true
  return true
end

function M.get(song, instrument, phrase)
  if instrument and not phrase_belongs(instrument,phrase) then return nil end
  local by_phrase, key = bucket(song, instrument, phrase, false)
  local draft = by_phrase and by_phrase[key]
  if draft then return clone_pattern(draft.pattern), draft.output_policy,draft.pb_range end
  if phrase and phrase_id(phrase)==0 then return nil end
  local index=instrument_index(song,instrument)
  if not index then return nil,"draft instrument is no longer in this song" end
  local pattern,policy_or_error,pb_range=
    store.read_draft(song,index,phrase_id(phrase),instrument.name)
  if not pattern then return nil,policy_or_error end
  return clone_pattern(pattern),policy_or_error,pb_range
end

function M.clear(song, instrument, phrase)
  local by_phrase, key = bucket(song, instrument, phrase, false)
  local index=instrument_index(song,instrument)
  local removed=false
  if index and (not phrase or phrase_id(phrase)>0) then
    local ok,err=store.clear_draft(song,index,phrase_id(phrase),instrument.name)
    if ok==nil then return nil,err end
    removed=ok==true
  end
  if not by_phrase or not by_phrase[key] then return removed end
  by_phrase[key] = nil
  if next(by_phrase) == nil then
    local by_instrument = drafts[song]
    by_instrument[instrument] = nil
    if next(by_instrument) == nil then drafts[song] = nil end
  end
  return true
end

function M.has(song)
  local by_instrument=drafts[song]
  local cached=by_instrument~=nil and next(by_instrument)~=nil
  if cached then return true end
  return store.has_drafts(song)
end

function M.has_volatile(song)
  local by_instrument=drafts[song]
  if not by_instrument then return false end
  for _,by_phrase in pairs(by_instrument) do
    for _,draft in pairs(by_phrase) do
      if not draft.persistent then return true end
    end
  end
  return false
end

return M
