# ARP.xrnx v0.2 (experimental)

Native Renoise 3.5+ pattern-to-pattern arpeggio generator.

Open **Tools > ARP...**. Select different sequencer tracks as source and destination, choose a rate in pattern lines and Up/Down/Up-Down ordering, then **Generate**.

The source is read from the selected pattern, including chord notes placed in visible note columns on the same line. Each new chord onset restarts the arpeggiator cycle. The latest chord plays until the next chord onset or pattern end. If an instrument number is present on the source chord, it is copied; otherwise the currently selected instrument is used.

**Write safety:** destination note column 1 must be completely empty throughout the selected pattern. The tool refuses to write if it is occupied, if the source and destination are the same, or if no source notes are found. Other destination note columns, effect columns and tracks are untouched.

**Known musical limitations:** only note-ons are emitted. Gate lengths, note-offs, deliberate rests, source note releases, hold/retrigger options, swing, delay, automatic regeneration, instrument selection in UI, and crossing pattern boundaries have **not** been implemented. Choose a short pluck or one-shot instrument to hear an arpeggio without sustained notes. Rate units are *Renoise pattern lines*, not note divisions.

The code is experimental and has not been executed inside a Renoise instance by the assistant. Test on a disposable song first. The older TB303 scaffold remains unchanged.
