dofile("tests/bootstrap.lua")("acid")
local context = require("runtime.context")
local sequencer = require("model.sequencer")
local phrase_fixture = dofile("tests/acid/runtime_phrase_fixture.lua")

local function new_context(drafts)
  return context.new{
    writer = {state = function() return "idle", nil end},
    sink = function() error("document lifetime checks must not dispatch") end,
    drafts = drafts,
  }
end

do
  local calls=0
  local ctx=context.new{writer={state=function()return "idle",nil end},
    sink=function()calls=calls+1;error("inactive context dispatched")end}
  assert(not ctx:request_generation("manual"),"detached context admitted generation")
  local song=phrase_fixture.fixture("new")
  ctx:attach_document(song)
  assert(not ctx:request_generation("manual"),"closed context admitted generation")
  ctx:open_dialog()
  assert(not ctx:request_generation("manual"),"context without an editor admitted generation")
  ctx:close_dialog()
  assert(not ctx:request_generation("manual"))
  ctx:release_document()
  assert(not ctx:request_generation("manual") and calls==0)
end

-- Reopened song wrappers keep persisted data and receive fresh runtime identity.
do
  local ctx = new_context()
  local phrase = phrase_fixture.phrase(sequencer.new_pattern(4),17)
  local instrument = phrase_fixture.instrument({phrase})
  local song = {tool_data = "persisted-source-output-record", instruments = {instrument},
    transport = {timing_model = 1, groove_enabled = false},
    is_undo_redoing = function() return false end}
  renoise.song = function() return song end

  assert(ctx:attach_document(song))
  ctx:open_dialog()
  local first = ctx:lifetime_state()
  assert(ctx:release_document())

  local fresh_phrase = phrase_fixture.phrase(sequencer.new_pattern(4),17)
  local fresh_instrument = phrase_fixture.instrument({fresh_phrase})
  local fresh_song = {tool_data = song.tool_data, instruments = {fresh_instrument},
    transport = {timing_model = 1, groove_enabled = false},
    is_undo_redoing = function() return false end}
  song = fresh_song
  renoise.song = function() return song end
  assert(ctx:attach_document(fresh_song))
  ctx:open_dialog()
  local reopened = ctx:lifetime_state()
  assert(reopened.epoch ~= first.epoch and reopened.session ~= first.session)
  assert(fresh_song.tool_data == "persisted-source-output-record")
  assert(fresh_phrase.name == phrase.name and #fresh_instrument.phrases == 1)
  assert(ctx:release_document())
end

-- Saved source records remain readable after host wrappers are reconstructed.
do
  local store = require("renoise.pattern_store")
  local current
  renoise.song = function() return current end
  local function saved_phrase()
    return phrase_fixture.phrase(sequencer.new_pattern(4),17)
  end

  local old_phrase = saved_phrase()
  local old_instrument = phrase_fixture.instrument({old_phrase})
  old_instrument.name = "Saved"
  local old_song = {instruments = {old_instrument},
    transport = {timing_model = 1, groove_enabled = false},
    is_undo_redoing = function() return false end}
  current = old_song
  assert(store.save(old_song, 17, sequencer.new_pattern(7), "play_once", 24))
  local bytes = old_song.tool_data

  local ctx = new_context()
  assert(ctx:attach_document(old_song))
  ctx:open_dialog()
  local old_epoch = ctx:lifetime_state().epoch
  assert(ctx:release_document())

  local fresh_phrase = saved_phrase()
  local fresh_instrument = phrase_fixture.instrument({fresh_phrase})
  fresh_instrument.name = "Saved"
  local fresh_song = {instruments = {fresh_instrument}, tool_data = bytes,
    transport = {timing_model = 1, groove_enabled = false},
    is_undo_redoing = function() return false end}
  current = fresh_song
  assert(ctx:attach_document(fresh_song))
  ctx:open_dialog()
  assert(ctx:lifetime_state().epoch ~= old_epoch)
  local source, policy, pb = store.load(fresh_song, fresh_instrument, fresh_phrase)
  assert(source and source.length == 7 and policy == "play_once" and pb == 24)
  assert(fresh_song.tool_data == bytes and fresh_phrase.name == old_phrase.name)
  assert(ctx:release_document())
end

-- Drafts remain during dialog close and clear when their document is released.
do
  local drafts = require("runtime.draft_cache")
  local instrument = {name = "Scratch", phrases = {}}
  local song = {instruments = {instrument}, tool_data = 42}
  renoise.song = function() return song end
  drafts.put(song, instrument, nil, sequencer.new_pattern(9), "repeat", 12)
  assert(drafts.has(song) and drafts.has_volatile(song))

  local ctx = new_context(drafts)
  assert(ctx:attach_document(song))
  ctx:open_dialog()
  ctx:close_dialog()
  assert(drafts.has(song) and drafts.has_volatile(song))
  ctx:open_dialog()
  local source, policy, pb = drafts.restore(song, instrument, nil)
  assert(source and source.length == 9 and policy == "repeat" and pb == 12)
  local released, warning = ctx:release_document()
  assert(released and warning == "Session-only ACID drafts were released")
  assert(not drafts.has(song) and not drafts.has_volatile(song))
end

print("ACID runtime document lifetime checks passed")
