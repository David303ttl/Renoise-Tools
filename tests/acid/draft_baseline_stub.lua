-- Draft integration fixtures supply verified values independently of native cells.
local ownership=require("renoise.phrase_ownership")
local real=assert(loadfile("com.david303ttl.ACID.xrnx/renoise/phrase_ownership.lua"))()
ownership.copy_snapshot=real.copy_snapshot
ownership.compare=real.compare
ownership.membership=real.membership
renoise=renoise or {}
renoise.InstrumentPhrase=renoise.InstrumentPhrase or {}
for key,value in pairs({MAX_NUMBER_OF_LINES=512,MAX_NUMBER_OF_NOTE_COLUMNS=12,
  MAX_NUMBER_OF_EFFECT_COLUMNS=8,PLAY_PATTERN=1,KEY_TRACKING_NONE=1}) do
  renoise.InstrumentPhrase[key]=value
end
local function validate(song,instrument,phrase)
  local member,err=ownership.membership(song,instrument,phrase)
  if not member or not phrase then return nil,err end
  if ownership.status(phrase)~="owned" then return nil,"Unverified target" end
  local source,policy,pb=require("renoise.pattern_store").load(song,instrument,phrase)
  if not source then return nil,policy end
  return {source=source,settings={output_policy=policy,pb_range=pb},
    baseline={content=phrase.baseline_revision or 0},planning_inputs={}}
end
local validator=require("writers.phrase_validator")
local retained=setmetatable({},{__mode="k"})
local retained_proofs=setmetatable({},{__mode="k"})
local function retained_record(reference)
  return retained[reference] or retained_proofs[reference]
end
function validator.retained_baseline(snapshot)
  local entry=retained_record(snapshot)
  if not entry then
    local sealed,err=ownership.copy_snapshot(snapshot)
    if not sealed then return nil,err end
    entry={snapshot=sealed,index={},identity={}}
    retained[snapshot]=entry
    retained[sealed]=entry
  end
  local reference=snapshot
  if retained[snapshot] then
    reference={}
    retained_proofs[reference]=entry
  end
  return entry.snapshot,entry.index,entry.identity,reference
end
function validator.retained_baseline_identity(snapshot)
  local entry=retained_record(snapshot)
  return entry and entry.identity
end
function validator.is_retained_baseline_identity(identity,snapshot)
  local entry=retained_record(snapshot)
  return entry~=nil and rawequal(identity,entry.identity)
end
function validator.classify_against(song,instrument,phrase,capabilities,capacities,options,snapshot,index)
  local entry=retained_record(snapshot)
  if not entry or not rawequal(entry.index,index) then
    return nil,"Phrase snapshot is not a retained verified baseline","unavailable"
  end
  local candidate,err=validate(song,instrument,phrase)
  if not candidate then return nil,err,"unavailable" end
  local same=ownership.compare(entry.snapshot,candidate.baseline)
  if not same then return nil,"Phrase differs from its verified baseline","unavailable" end
  candidate.baseline=entry.snapshot
  return candidate
end
validator.classify=validate
return validate
