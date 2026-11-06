# ACID phrase playback checks

Use a disposable song and an instrument with an audible receiver. Generate a
phrase with **Generate**, then select it in Renoise's instrument Phrase Editor.

1. Set native phrase playback to **Prg** and select the generated phrase
   program. In the Pattern Editor, trigger the instrument with C-4 on a sequencer
   track and place OFF after the listening interval. Start transport, listen, stop
   and retrigger. Check receiver output, release and a Repeat end-to-start slide.
2. Arrange the trigger pattern in the Pattern Sequencer and add another trigger
   at a known song position. Compare stop/retrigger with continuous phrase looping.
   Phrase switches do not guarantee inherited note or slide continuity.
3. On a separate copy, enable native key tracking **Transpose**, set base note
   C-4, then trigger C-4 and D-4. Check receiver transposition. Separately use
   Renoise's phrase selection transpose command and check the result. ACID must
   reject **Generate** if the native edit invalidates destination ownership while
   retaining the source draft.
4. Change native phrase length and confirm ACID rejects the modified
   destination. Change ACID **Length** or **Pitch span** instead and confirm the
   owned phrase can be generated from the edited source. These source bounds do
   not discard the other stored slots.

Use the [timing checks](acid_timing_manual.md) for Straight/Triplet, Play Once,
Repeat and loop-seam behavior, and the [destination checks](acid_phrase_destination_manual.md)
for ownership and save/reopen behavior.
