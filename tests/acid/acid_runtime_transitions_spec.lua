dofile('tests/bootstrap.lua')('acid')
local transitions=require('runtime.transitions')
local engine=transitions.new()
local eq_calls=0
local equality={__eq=function()eq_calls=eq_calls+1;return true end}
local a,b=setmetatable({},equality),setmetatable({},equality)
local instrument={}
local effects=engine:transition('target',{instrument=instrument,phrase=a,kind='owned'})
assert(effects.bind and effects.preserve_draft and effects.revoke=='all')
assert(effects.revisions.target_revision==1)
local before=engine:revision_state()
effects=engine:transition('refresh')
assert(not effects.revoke and effects.revisions.operation_serial==before.operation_serial)
effects=engine:transition('target',{instrument=instrument,phrase=b,kind='owned'})
assert(effects.revisions.target_revision==2)
effects=engine:transition('target',{instrument=instrument,phrase=a,kind='owned'})
assert(effects.revisions.target_revision==3 and eq_calls==0)
effects=engine:transition('target',{instrument=instrument,phrase=a,kind='owned'})
assert(not effects.bind and not effects.revoke and effects.revisions.target_revision==3)

-- Editor changes keep revision identity even when later values return to A.
engine:transition('arm')
for revision=1,3 do
 effects=engine:transition('edit',{changed=true,valid=true,eligible=true})
 assert(effects.live_intent and effects.revisions.edit_revision==revision)
end
before=engine:revision_state()
effects=engine:transition('edit',{changed=false,valid=true,eligible=true})
assert(not effects.live_intent and not effects.revoke)
assert(effects.revisions.edit_revision==before.edit_revision)
for _,kind in ipairs({'programmatic','reset','recovery'})do
 effects=engine:transition(kind,{changed=true})
 assert(effects.revoke=='all' and not effects.live_intent and not effects.request)
end
effects=engine:transition('edit',{changed=true,valid=false,eligible=false})
assert(effects.preserve_draft and not effects.live_intent)
effects=engine:transition('edit',{changed=true,valid=true,eligible=false})
assert(effects.preserve_draft and not effects.live_intent)

-- Disarming revokes only live intent; manual request revisions remain current.
effects=engine:transition('request',{trigger='manual'})
local manual=effects.revisions
effects=engine:transition('disarm')
assert(effects.revoke=='live' and effects.revisions.operation_serial==manual.operation_serial)
effects=engine:transition('request',{trigger='live'})
assert(not effects.request and not effects.revoke)
assert(effects.revisions.operation_serial==manual.operation_serial)
effects=engine:transition('completion',{operation_serial=manual.operation_serial,
 target_revision=manual.target_revision,edit_revision=manual.edit_revision,success=true})
assert(effects.apply_success)
effects=engine:transition('completion',{operation_serial=manual.operation_serial,
 target_revision=manual.target_revision,edit_revision=manual.edit_revision,success=true})
assert(not effects.apply_success,'duplicate completion cannot apply twice')
engine:transition('arm')
effects=engine:transition('request',{trigger='live'})
local live=effects.revisions
effects=engine:transition('disarm')
assert(effects.revisions.operation_serial>live.operation_serial)
effects=engine:transition('completion',{operation_serial=live.operation_serial,
 target_revision=live.target_revision,edit_revision=live.edit_revision,success=true})
assert(not effects.apply_success and effects.reconcile)
effects=engine:transition('edit',{changed=true,valid=true,eligible=true})
assert(not effects.live_intent and effects.preserve_draft)

-- Observation, guarded actions and completion never request music themselves.
for _,kind in ipairs({'external','undo','close','blocker','independence'})do
 before=engine:revision_state()
 effects=engine:transition(kind,{semantic_changed=true})
 assert(effects.revoke=='all' and not effects.request and not effects.live_intent)
 assert(effects.revisions.operation_serial==before.operation_serial+1)
 if kind=='external' or kind=='undo' then
  assert(effects.revisions.target_revision==before.target_revision+1)
 end
end
before=engine:revision_state()
effects=engine:transition('refresh',{semantic_changed=true})
assert(effects.detach_draft and effects.revisions.target_revision==before.target_revision+1)
local detached=engine:revision_state();detached.armed=true;detached.edit_revision=999
assert(not engine:revision_state().armed and engine:revision_state().edit_revision~=999)
engine:release()
assert(engine:revision_state().target_revision==0 and not engine:revision_state().armed)
print('ACID runtime transition revisions and arming decisions passed')
