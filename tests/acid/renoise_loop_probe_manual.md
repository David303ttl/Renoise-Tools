# ACID phrase-loop probe

Run `renoise_loop_probe.lua` in a disposable song with the `ACID LOOP PROBE`
instrument and a playable sample. The probe uses phrase LPB 16 and four lines
per straight TIME step.

The endpoint phrases compare loop ranges 1-32 and 1-33 in a 33-line phrase,
then loop lines 33-64 in a 65-line phrase. The mixed NOTE/TIE/NOTE/REST phrase
uses lines 1, 9, and 13 in a 16-line phrase. Inspect marker order, release,
loop period, and sentinel behavior after a single host trigger.

Use Renoise's Scripting Terminal:

```lua
dofile("<repository-root>/tests/acid/renoise_loop_probe.lua")
```

Record Renoise version, BPM, phrase LPB, loop properties, sample setup, and
observations. Current-layout Renoise playback checks have not been performed in
this work session.
