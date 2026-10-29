-- Draft integration fixtures supply verified values independently of native cells.
local ownership=require("writers.phrase_ownership")
local real=assert(loadfile("com.david303ttl.ACID.xrnx/writers/phrase_ownership.lua"))()
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
  local source,policy,pb=require("model.pattern_store").load(song,instrument,phrase)
  if not source then return nil,policy end
  return {source=source,settings={output_policy=policy,pb_range=pb},
    baseline={content=phrase.baseline_revision or 0},planning_inputs={}}
end
require("writers.phrase_validator").classify=validate
return validate
