dofile("tests/bootstrap.lua")("acid")
local context = require("runtime.context")

local assert_unreachable = dofile('tests/assert_unreachable.lua')

do
  local forbidden, cycle = {}, {}
  cycle.self = cycle
  assert_unreachable(cycle, {song = forbidden})
  for _, retained in ipairs({{[forbidden] = true},
    setmetatable({}, {__index = forbidden}), function() return forbidden end}) do
    assert(not pcall(assert_unreachable, retained, {song = forbidden}))
  end
end

local function fixture(reject)
  local song = {tool_data = "persisted-source-output-record", instruments = {}}
  local instrument = {phrases = {}}
  local phrase = {name = "saved-owned-phrase"}
  song.instruments[1], instrument.phrases[1] = instrument, phrase
  local widget = {visible = true}
  local log = {captures = 0, deliveries = 0, cancels = 0, detaches = 0,
    releases = 0, requests = {}, completions = {}}
  local writer = {status = "idle"}
  function writer:state() return self.status, self.token end
  local function capture(_, token)
    log.captures = log.captures + 1
    local request = {token = token, song = song, instrument = instrument,
      phrase = phrase, frozen = {source = {note = 48}}}
    request.nested = function() return song, instrument, phrase, widget end
    return request
  end
  local function gui_delivery()
    assert(widget.visible)
    log.deliveries = log.deliveries + 1
  end
  local ctx = context.new{
    writer = writer, capture = capture,
    sink = function(request, done)
      log.requests[#log.requests + 1] = request
      log.completions[#log.completions + 1] = done
      if reject then return false, "rejected" end
      writer.status, writer.token = "busy", request.token
      return true
    end,
    cancel = function(token)
      assert(token:is_current() == false, "invalidate before cancellation")
      log.cancels = log.cancels + 1
      return true
    end,
    detach = function(value)
      assert(type(value) == "table" and value.tool_data == song.tool_data)
      log.detaches = log.detaches + 1
    end,
    drafts = {release = function(value)
      assert(type(value) == "table" and value.tool_data == song.tool_data)
      log.releases = log.releases + 1
      return true, "Session-only ACID drafts were released"
    end},
  }
  return ctx, writer, log, song, instrument, phrase, widget, capture, gui_delivery
end

-- Released settled and rejected callbacks must lose their captured context as
-- thoroughly as a callback retained by an unresolved render.
do
  for _, rejected in ipairs({false, true}) do
    local ctx, writer, log, song, instrument, phrase, widget, capture, gui = fixture(rejected)
    ctx:attach_document(song)
    ctx:open_dialog(gui)
    assert(ctx:request_generation("retired") == not rejected)
    local done, token = log.completions[1], log.requests[1].token
    if not rejected then
      writer.status, writer.token = "idle", nil
      assert(done({status = "committed"}))
    end
    ctx:release_document()
    assert_unreachable({token, done}, {song = song, instrument = instrument,
      phrase = phrase, widget = widget, capture = capture, gui_delivery = gui,
      request = log.requests[1]})
  end
end

-- Closing a dialog revokes delivery without discarding the live document or
-- pretending that cancellation acknowledgement settles an accepted writer.
do
  local ctx, writer, log, song, _, _, _, _, gui = fixture()
  ctx:attach_document(song)
  ctx:open_dialog(gui)
  local first = ctx:lifetime_state()
  assert(ctx:request_generation("first"))
  local old_token, old_done = writer.token, log.completions[1]
  ctx:close_dialog()
  ctx:close_dialog()
  assert(old_token:is_current() == false and log.cancels == 1)
  assert(log.releases == 0 and log.detaches == 0)
  assert(writer.status == "busy" and rawequal(writer.token, old_token))
  ctx:open_dialog(gui)
  local reopened = ctx:lifetime_state()
  assert(reopened.epoch == first.epoch and reopened.session ~= first.session)
  assert(ctx:request_generation("occupied") == false and log.captures == 1)
  writer.status, writer.token = "idle", nil
  assert(old_done({status = "committed"}) == true)
  assert(log.deliveries == 0)
  assert(ctx:request_generation("new-session"))
  local new_token, new_done = writer.token, log.completions[2]
  assert(old_done({status = "committed"}) == false)
  assert(new_token:is_current(), "duplicate old completion revoked new session")
  writer.status, writer.token = "idle", nil
  assert(new_done({status = "committed"}) == true)
  assert(log.deliveries == 1)
end

-- Close cancels unresolved accepted work even after authorization was revoked;
-- neither failed cancellation nor acknowledgement substitutes for completion.
do
  for _, acceptance in ipairs({"revoke", "invalid result", "throw"}) do
    for _, cancellation in ipairs({"acknowledged", "rejected", "throw"}) do
      local label = acceptance .. " / " .. cancellation
      local writer = {status = "idle"}
      function writer:state() return self.status, self.token end
      local done, token
      local cancels, captures, deliveries = 0, 0, 0
      local ctx = context.new{
        writer = writer,
        capture = function(_, issued)
          captures = captures + 1
          return {token = issued}
        end,
        sink = function(request, finish)
          token, done = request.token, finish
          writer.status, writer.token = "busy", token
          if acceptance == "invalid result" then return nil end
          if acceptance == "throw" then error("failed after writer acceptance") end
          return true
        end,
        cancel = function(issued)
          assert(rawequal(issued, token) and not issued:is_current(), label)
          cancels = cancels + 1
          if cancellation == "throw" then error("cancellation failed") end
          return cancellation == "acknowledged"
        end,
      }
      ctx:attach_document({})
      ctx:open_dialog(function() deliveries = deliveries + 1 end)
      assert(ctx:request_generation("first"), label)
      if acceptance == "revoke" then
        assert(ctx:revoke(token, "external invalidation"), label)
      end
      assert(not token:is_current() and cancels == 0, label)
      assert(ctx:close_dialog() == true, label)
      assert(ctx:close_dialog() == false and cancels == 1, label)
      assert(writer.status == "busy" and rawequal(writer.token, token), label)
      local pending = ctx:state()
      assert(rawequal(pending.token, token) and pending.authorization == false, label)
      ctx:open_dialog(function() deliveries = deliveries + 1 end)
      assert(ctx:request_generation("occupied") == false and captures == 1, label)
      writer.status, writer.token = "idle", nil
      assert(ctx:request_generation("awaiting-terminal") == false, label)
      assert(captures == 1 and rawequal(ctx:state().token, token), label)
      assert(done({status = "cancelled"}) == true, label)
      assert(ctx:state().token == nil and deliveries == 0, label)
    end
  end
end

-- Release removes host and GUI references from every table/closure reachable
-- through a retained token or terminal callback, even while rendering stalls.
do
  local ctx, writer, log, song, instrument, phrase, widget, capture, gui = fixture()
  ctx:attach_document(song)
  ctx:open_dialog(gui)
  assert(ctx:request_generation("release"))
  local token, done = writer.token, log.completions[1]
  local epoch = ctx:lifetime_state().epoch
  ctx:release_document()
  ctx:release_document()
  ctx:close_dialog()
  assert(token:is_current() == false)
  assert(log.cancels == 1 and log.detaches == 1 and log.releases == 1)
  assert(writer.status == "busy" and rawequal(writer.token, token))
  assert_unreachable({token, done}, {song = song, instrument = instrument,
    phrase = phrase, widget = widget, capture = capture, gui_delivery = gui,
    frozen_request = log.requests[1], frozen_source = log.requests[1].frozen})
  local next_song = {tool_data = song.tool_data, instruments = {}}
  ctx:attach_document(next_song)
  ctx:open_dialog(function() log.deliveries = log.deliveries + 1 end)
  assert(ctx:lifetime_state().epoch ~= epoch)
  assert(ctx:request_generation("new-song-occupied") == false)
  assert(log.captures == 1 and log.deliveries == 0)
  writer.status, writer.token = "idle", nil
  assert(done({status = "committed", song = song}) == true)
  local settled = ctx:state()
  assert(settled.status == "idle" and settled.token == nil)
  assert(settled.authorization == false)
  assert(ctx:request_generation("new-song"))
  local new_token, new_done = writer.token, log.completions[2]
  assert(done({status = "committed"}) == false)
  local pending = ctx:state()
  assert(pending.status == "pending" and pending.blocked == false)
  assert(rawequal(pending.token, new_token) and pending.authorization == true)
  assert(new_token:is_current() and writer.status == "busy")
  assert(log.deliveries == 0)
  assert_unreachable({token, done}, {song = song, instrument = instrument,
    phrase = phrase, widget = widget, gui_delivery = gui})
  writer.status, writer.token = "idle", nil
  assert(new_done({status = "committed"}) == true)
  assert(log.deliveries == 1)
  assert(ctx:state().status == "idle" and ctx:state().token == nil)
end

-- Reloaded wrappers preserve saved data and receive fresh runtime identity.
-- Classification belongs to the next boundary; lifetime restores no ownership.
do
  local ctx, _, log, old_song = fixture()
  ctx:attach_document(old_song)
  ctx:open_dialog(function() error("opening must not deliver") end)
  local old = ctx:lifetime_state()
  ctx:release_document()
  local fresh_phrase = {name = old_song.instruments[1].phrases[1].name}
  local fresh_instrument = {phrases = {fresh_phrase}}
  local fresh_song = {tool_data = old_song.tool_data, instruments = {fresh_instrument}}
  assert(not rawequal(fresh_song, old_song))
  ctx:attach_document(fresh_song)
  ctx:open_dialog(function() error("reloading must not deliver") end)
  local current = ctx:lifetime_state()
  assert(current.epoch ~= old.epoch and current.session ~= old.session)
  assert(fresh_song.tool_data == "persisted-source-output-record")
  assert(fresh_phrase.name == "saved-owned-phrase" and #fresh_instrument.phrases == 1)
  assert(log.captures == 0 and log.deliveries == 0)
  ctx:release_document()
  ctx:attach_document(fresh_song)
  assert(ctx:lifetime_state().epoch ~= current.epoch,
    "reattaching the same host object after release needs a fresh epoch")
end

-- A lifecycle transition inside capture must revoke the installed admission
-- before any sink can accept the now-stale request.
do
  for _, transition in ipairs({"close_dialog", "release_document"}) do
    local ctx, token, sink_calls
    sink_calls = 0
    ctx = context.new{
      writer = {state = function() return "idle", nil end},
      capture = function(_, issued)
        token = issued
        ctx[transition](ctx)
        return {token = issued, song = {old = true}}
      end,
      sink = function() sink_calls = sink_calls + 1; return true end,
    }
    ctx:attach_document({})
    ctx:open_dialog(function() error("stale capture delivered") end)
    assert(ctx:request_generation("interrupted-capture") == false, transition)
    assert(sink_calls == 0 and token:is_current() == false, transition)
  end
end

-- Saved source records remain readable using fresh host wrappers, without an
-- old token, baseline or dialog state supplying any part of their identity.
do
  local seq = require("model.sequencer")
  local own = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local current
  renoise = {song = function() return current end}
  local function saved_phrase()
    local p = {number_of_lines = 1, visible_note_columns = 1, visible_effect_columns = 0}
    function p:line() return {note_columns = {{note_value = 48, instrument_value = 255,
      volume_value = 255, panning_value = 255, delay_value = 0,
      effect_number_value = 0, effect_amount_value = 0}}} end
    function p:column_is_muted() return false end
    p.name = assert(own.make_name(p, 17))
    return p
  end
  local old_phrase = saved_phrase()
  local old_instrument = {name = "Saved", phrases = {old_phrase}}
  local old_song = {instruments = {old_instrument}}
  current = old_song
  assert(store.save(old_song, 17, seq.new_pattern(7), "play_once", 24))
  local bytes = old_song.tool_data
  local ctx = context.new{writer = {state = function() return "idle", nil end},
    capture = function() error("reload must not capture") end,
    sink = function() error("reload must not dispatch") end}
  ctx:attach_document(old_song)
  ctx:open_dialog()
  local old_epoch = ctx:lifetime_state().epoch
  ctx:release_document()
  local fresh_phrase = saved_phrase()
  local fresh_instrument = {name = "Saved", phrases = {fresh_phrase}}
  local fresh_song = {instruments = {fresh_instrument}, tool_data = bytes}
  current = fresh_song
  ctx:attach_document(fresh_song)
  ctx:open_dialog()
  assert(ctx:lifetime_state().epoch ~= old_epoch)
  local source, policy, pb = store.load(fresh_song, fresh_instrument, fresh_phrase)
  assert(source and source.length == 7 and policy == "play_once" and pb == 24)
  assert(fresh_song.tool_data == bytes and fresh_phrase.name == old_phrase.name)
end

-- Revocation alone is not writer cancellation. Release still asks for cleanup,
-- and synchronous cleanup hooks cannot recursively release or start requests.
do
  local ctx, done, token
  local cancels, detaches, releases, captures = 0, 0, 0, 0
  local writer = {state = function() return "idle", nil end}
  ctx = context.new{writer = writer,
    capture = function(_, issued)
      captures = captures + 1
      token = issued
      return {token = issued}
    end,
    sink = function(_, finish) done = finish; return true end,
    cancel = function()
      cancels = cancels + 1
      assert(not token:is_current())
      assert(ctx:release_document() == false)
      assert(ctx:request_generation("during-release") == false)
    end,
    detach = function()
      detaches = detaches + 1
      assert(ctx:release_document() == false)
    end,
    drafts = {release = function()
      releases = releases + 1
      assert(ctx:release_document() == false)
      return true
    end}}
  ctx:attach_document({})
  ctx:open_dialog()
  assert(ctx:request_generation("first"))
  assert(ctx:revoke(token, "external invalidation"))
  assert(ctx:release_document())
  assert(cancels == 1 and detaches == 1 and releases == 1 and captures == 1)
  assert(done({}) == true and done({}) == false)
end

-- Real object-local scratch drafts survive close and report volatile loss at
-- release when the backing song record cannot be persisted.
do
  local seq = require("model.sequencer")
  local drafts = require("runtime.draft_cache")
  local instrument = {name = "Scratch", phrases = {}}
  local song = {instruments = {instrument}, tool_data = 42}
  renoise = {song = function() return song end}
  drafts.put(song, instrument, nil, seq.new_pattern(9), "repeat", 12)
  assert(drafts.has(song) and drafts.has_volatile(song))
  local ctx = context.new{writer = {state = function() return "idle", nil end},
    capture = function() error("draft lifetime must not capture") end,
    sink = function() error("draft lifetime must not dispatch") end,
    drafts = drafts}
  ctx:attach_document(song)
  ctx:open_dialog()
  ctx:close_dialog()
  assert(drafts.has(song) and drafts.has_volatile(song))
  ctx:open_dialog()
  local source, policy, pb = drafts.get(song, instrument, nil)
  assert(source and source.length == 9 and policy == "repeat" and pb == 12)
  local released, warning = ctx:release_document()
  assert(released and warning == "Session-only ACID drafts were released")
  assert(not drafts.has(song) and not drafts.has_volatile(song))
end

print("ACID runtime document and dialog lifetime checks passed")
