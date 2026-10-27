# ACID.xrnx

ACID is an experimental Renoise 3.5 / scripting API 6.2 phrase-based
sequencer. It edits independent PITCH and TIME memories and generates a native
instrument phrase; Renoise supplies the instrument, transport and arrangement.
The manifest remains at version 0.1.

Open **Tools > ACID...** or the Pattern Editor context menu. Choose a sample
instrument and an existing unchanged ACID-owned phrase or **New Phrase**.
Set LAST STEP and create a draft, then edit PITCH and TIME. A NOTE consumes the
next active PITCH entry; TIE holds the current semantic voice, and REST releases
it. ACCENT and outgoing SLIDE belong to the PITCH entry. Entering TIE at TIME
01 stores NOTE.

Original entry supports 1–16 straight TIME steps with an active span of 16
pitches. Extended entry supports 1–64 steps and an independent active PITCH
span of 1–64. All 64 pitch positions are retained when inactive; the four
editor pages form one continuous sequence. PITCH consumption starts at P01 on
each TIME traversal. Original and Extended use the same interpretation; the
cursor policy is an ACID decision rather than a measured original-hardware
claim. Triplets are not implemented.

Generate or regenerate explicitly, or enable Live Edit for debounced automatic
regeneration of an eligible destination. The current source is stored with the
song. ACID refuses foreign or modified phrases and unsupported earlier
source/seal formats; recreate older development patterns instead of adopting
them. Do not use the tool as a backup for unrelated song data.

New drafts default to Repeat. Repeat currently supports baseline NOTE/TIE/REST
generation; slide transitions and non-baseline audio modes are refused in
Repeat. One-shot remains available as a separate playback setting. The native
endpoint, hand-built mixed-event, and ACID writer WAV probes pass their recorded
pitch/grid checks. The writer was checked for lengths 1, 16, 17, 32, 33, 48,
49 and 64 with a sustained trigger over three cycles. Sample release/cut tail,
voice continuity, selective slide, gate duration, stop/start, seek, undo and
broader save/reopen behavior remain open checks in
[the loop verification protocol](../tests/acid/acid_loop_manual.md).
A semantic slide request is not proof of envelope-continuous sample glide or
TB-303 acoustic fidelity. Unsupported Repeat cases are refused with a status.

The model and evidence decisions are described in [DESIGN.md](DESIGN.md),
[M2_SEMANTICS.md](M2_SEMANTICS.md), and [ROADMAP.md](ROADMAP.md).

## Local checks

From the repository root in PowerShell 7:

```powershell
./scripts/run_tests.ps1 -Tool ACID
./tests/acid/validate_loop_oracle.ps1
./scripts/package.ps1 -Tool ACID
```

Each Lua spec runs in a separate process. Mock and semantic checks do not
establish actual Renoise audio behavior. The package has `manifest.xml` and
`main.lua` at its root; development references and tests are excluded.

For development, copy or symlink `com.david303ttl.ACID.xrnx` into Renoise's
user `Scripts/Tools` folder and reload tools, or install the package produced in
`dist/`. Remove earlier development copies to avoid duplicate menu entries.
