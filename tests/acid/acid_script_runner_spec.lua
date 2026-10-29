dofile("tests/bootstrap.lua")("acid")
local runner_module = require("writers.script_runner")
local function fixture(mode)
  local listeners = {}
  local observable = {}
  function observable:add_notifier(fn) listeners[fn] = true end
  function observable:remove_notifier(fn) listeners[fn] = nil end
  function observable:fire()
    local pending = {}
    for fn in pairs(listeners) do pending[#pending+1] = fn end
    for _, fn in ipairs(pending) do fn() end
  end
  local script = {committed_observable=observable, renders=0}
  function script:commit()
    if mode == "commit_error" then error("commit failed") end
    if mode == "synchronous" or mode == "commit_after_render_error" then observable:fire() end
    if mode == "commit_after_render_error" then error("commit returned after render start") end
  end
  function script:render_to_pattern(options, done)
    self.renders = self.renders + 1
    assert(options.lpb == 8)
    self.done = done
    if mode == "refuse" then return false, "busy" end
    if mode == "throw" then error("native failure") end
    if mode == "throw_after_callback" then done(nil, 3, 0);error("native failure after completion") end
    if mode == "synchronous" then done(nil, 3, 0) end
    return true
  end
  local calls, rendering, result = 0, 0
  local runner = runner_module.new(script, {lpb=8}, {
    rendering=function()
      rendering=rendering+1
      if mode == "hook_error" then error("status callback failed") end
    end,
    done=function(err, events, skipped)
      calls=calls+1
      result={err=err, events=events, skipped=skipped}
    end})
  return runner, script, observable, function() return calls, rendering, result end
end
local runner, script, observable, results = fixture()
assert(runner:start())
assert(script.renders == 0 and runner.phase == "committing")
observable:fire()
assert(script.renders == 1 and runner.phase == "rendering")
assert(not runner:cancel())
observable:fire()
assert(script.renders == 1)
script.done(nil, 4, 0)
script.done("duplicate", 0, 0)
local calls, rendering, result = results()
assert(calls == 1 and rendering == 1 and result.events == 4 and not result.err)
assert(runner.phase == "done")
runner, script, observable, results = fixture()
assert(runner:start() and runner:cancel())
observable:fire()
assert(script.renders == 0 and results() == 0 and runner.phase == "cancelled")
for _, mode in ipairs({"synchronous", "refuse", "throw_after_callback"}) do
  runner, script, observable, results = fixture(mode)
  assert(runner:start())
  observable:fire()
  calls, rendering, result = results()
  assert(calls == 1 and rendering == 1 and runner.phase == "done")
  assert((result.err ~= nil) == (mode == "refuse"))
end
runner, script, observable, results = fixture("throw")
assert(runner:start())
observable:fire()
assert(runner.phase == "rendering" and runner.error:find("native failure", 1, true))
assert(results() == 0 and not runner:cancel())
script.done(nil, 3, 0)
assert(results() == 1 and runner.phase == "done")
runner, script, observable, results = fixture("hook_error")
assert(runner:start())
observable:fire()
calls, rendering, result = results()
assert(calls == 1 and result.err:find("status callback failed", 1, true))
assert(script.renders == 0 and runner.phase == "done")
runner, script, observable, results = fixture("commit_error")
local ok, err = runner:start()
assert(not ok and err:find("commit failed", 1, true))
observable:fire()
assert(script.renders == 0 and results() == 0)
runner, script, observable, results = fixture()
assert(runner:start())
observable:fire()
runner:detach()
assert(runner.phase == "rendering" and not runner:cancel())
script.done(nil, 2, 0)
assert(results() == 1 and runner.phase == "done")
runner, script, observable, results = fixture()
assert(runner:start())
runner:detach()
observable:fire()
assert(runner.phase == "cancelled" and script.renders == 0 and results() == 0)
runner, script, observable, results = fixture("commit_after_render_error")
assert(runner:start())
assert(runner.phase == "rendering" and results() == 0)
script.done(nil, 3, 0)
assert(runner.phase == "done" and results() == 1)
local detached_script = {renders=0}
local detached_observable = {}
function detached_observable:add_notifier(fn) self.fn=fn end
function detached_observable:remove_notifier() self.fn=nil end
detached_script.committed_observable=detached_observable
function detached_script:commit() detached_observable.fn() end
function detached_script:render_to_pattern() self.renders=self.renders+1 end
local detached_calls=0
local detached_runner
detached_runner=runner_module.new(detached_script, {}, {
  rendering=function() detached_runner:detach() end,
  done=function(err) assert(err);detached_calls=detached_calls+1 end})
assert(detached_runner:start())
assert(detached_script.renders == 0 and detached_calls == 1)
print("ACID script runner checks passed")
