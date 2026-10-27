local sequencer=require("model.sequencer")

return function(note,accent,slide)
  assert(type(note)=="number" and note%1==0 and note>=24 and note<=60,
    "test pitch must fit the current key/octave controls")
  local key,octave
  if note<36 then key,octave=note-24,-1
  elseif note>48 then key,octave=note-48,1
  else key,octave=note-36,0 end
  return sequencer.new_pitch(key,octave,accent,slide)
end
