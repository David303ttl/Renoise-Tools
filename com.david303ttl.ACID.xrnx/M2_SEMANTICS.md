# ACID M2 loop semantics

This document is the M2.0 conformance oracle for the repeating interpreter.
It records chosen ACID behavior and separates it from evidence
about the original instrument and the OS-303 replacement firmware. It does not
claim that native phrase playback has passed verification.

The machine-readable cases are in
[`tests/acid/fixtures/loop_cases.json`](../tests/acid/fixtures/loop_cases.json).
The checked Roland references and pinned firmware source map are in
[`M2_BLUEPRINT.md`](M2_BLUEPRINT.md#2-reference-evidence-and-original-hardware-differences).

## Evidence and scope

The April 1982 Roland manual establishes separate PITCH and TIME entry,
repeating playback, outgoing SLIDE behavior, REST interruption, equal-pitch
slide as a tie, and the entry rule that converts a leading TIE to NOTE (R01–R03).
It specifies straight lengths 1–16 and triplet lengths 1–15 (R04). These are
operator-facing observations, not CPU cursor traces or measurements of voice
envelopes.

The pinned OS-303 source resets its PITCH cursor at TIME wrap and consumes
PITCH on NOTE, but uses one shared length and resets before reading TIME 01.
Its leading-TIE output can consequently read PITCH[0] instead of the held pitch.
That source-level difference is documented as evidence, not copied as ACID
behavior. Original hardware's exact PITCH cursor behavior and the acoustic
result of loop-boundary glide remain unresolved.

Original entry is a programming subset: straight TIME length 1–16 and active
PITCH span 16. Extended permits TIME length 1–64 and active PITCH span 1–64.
Both modes store 64 valid PITCH entries, defaulting to C. The Original defaults
and capacity are ACID policies; they do not assert how unentered hardware
memory is initialized. Length alone does not establish Original conformance.
Triplets are outside M2 and belong to M4.

## Source and cursor decisions

TIME and PITCH are independent memories. Only NOTE consumes a pitch. TIE and
REST consume none. The active PITCH sequence is the prefix P01 through Pnn,
where `pitch_length` is explicit and independent of TIME length and of the
number of supplied or edited pitch values. After consuming Pnn, the next NOTE
consumes P01. At every complete TIME-cycle boundary, the next-consumed pitch
resets to P01. These are fixed ACID rules informed by OS-303, not claims about
original CPU implementation.

The semantic voice is separate from the consumption cursor. The voice retains
the last sounding pitch and outgoing SLIDE state across TIME wrap. A REST clears
that voice and its slide connection. A TIE holds the current voice without
consuming a pitch; a TIE while silent remains silent. This gives a leading REST
on a repeated cycle the prior voice for that REST to release. A NOTE after a
REST attacks. At a cold start, no voice exists and the first NOTE attacks.

At repetition, the first NOTE receives the final held voice's outgoing SLIDE
intent if no REST intervenes. Different pitches request a glide; equal pitches
request a tied connection. A leading REST breaks that connection.
These are semantic transitions only: native sample voice continuity, envelope
behavior, and gate timing require Renoise playback checks and are not inferred
from phrase cells.

## Terms used by the oracle

- **Initial trigger:** the first traversal from a cold state with no held voice.
  A leading NOTE attacks. A REST releases nothing. A leading TIE is not
  canonical source. Only cycle 1 starts silent; later cycles inherit semantic
  voice state from the prior cycle.
- **Subsequent loop:** a TIME traversal after the initial traversal. PITCH
  consumption restarts at P01 while held voice identity carries across the
  boundary until a REST clears it or a NOTE changes it.
- **Leading TIE:** a TIE at TIME 01. An entry command converts it to NOTE in
  both modes before preview/compile; editing stores NOTE but does not itself
  consume a pitch. On traversal, that NOTE consumes P01. A loaded or directly
  compiled source containing the TIE is rejected; compilation never rewrites
  source.
- **Trailing TIE:** a TIE at LAST STEP. It holds the current voice, consumes no
  pitch, and leaves its outgoing SLIDE intent available to the next cycle's
  first NOTE if no REST intervenes.
- **Ending REST:** a REST at LAST STEP. It releases any current voice; the next
  cycle starts without a held voice and its first NOTE attacks.
- **Next NOTE:** the next NOTE command in TIME order receives the next active
  PITCH entry. TIE and REST do not advance this cursor. The cursor wraps at
  `pitch_length`, even if NOTE count differs from the active span, and resets
  to P01 at the beginning of every TIME cycle.

## Unequal NOTE count and PITCH span

The chosen reset-each-cycle policy makes mismatched counts deterministic. Five
NOTE commands with three active pitches consume P01, P02, P03, P01, P02 on each
cycle. Three NOTE commands with five active pitches consume P01, P02, P03;
P04 and P05 remain stored but unused in that cycle. The next cycle starts again
at P01. The fixture has both cases so an implementation cannot derive playback
length from the 64-entry capacity or carry an unfinished cursor across cycles.

## Fixture oracle

[`loop_cases.json`](../tests/acid/fixtures/loop_cases.json) contains
hand-authored expectations for three cycles, entry normalization and refusal,
cutover refusal, boundary transitions, and lengths 1, 16, 17, 32, 33, 48, 49,
and 64. Indices are one-based and note values are Renoise note values. Every
fixture starts cold and silent on cycle 1; subsequent cycles carry held voice
state independently of the reset PITCH cursor. Additional cases cover
multi-step all-N and all-R cycles and exact active-span wrap at 16 and 64.

Expected records describe semantic note consumption, ties, releases, requested
transitions, and exit state. They do not assert sample-envelope continuity or
analog measurements. Cycle fixtures are hand-authored independently of
production interpreter output. Run
[`tests/acid/validate_loop_oracle.ps1`](../tests/acid/validate_loop_oracle.ps1)
from the repository root to check fixture structure and internal consistency.
That check does not execute an ACID runtime interpreter. No result in this
document or fixture proves Renoise playback, undo, save/reopen, or
original-hardware behavior.
