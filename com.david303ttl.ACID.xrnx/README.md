# ACID.xrnx

ACID is an experimental Renoise 3.5 / scripting API 6.2 phrase-based
sequencer. It edits independent PITCH and TIME memories and generates a native
instrument phrase; Renoise supplies the instrument, transport and arrangement.
The manifest remains at version 0.1.

M3 implementation is complete for the verified reference-profile matrix.
The fresh package is installed and matches the repository. All 24 ACID Lua
specs and 11 PowerShell checks pass. Live transport stop/start, seek and Live
Edit during playback remain the outstanding M3 acceptance checks; see
[the evidence record](../tests/acid/audio_capture_evidence.md).

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

New drafts default to Repeat. Repeat NOTE/TIE/REST generation is available on
the checked diagnostic profile at 90/120/150 BPM/selective/LPB8/TPL12/no
groove. All 21 authored gate protocols pass across those three tempos.
Selective same-pitch and moving slide generation is limited to the measured
Repeat layouts, lengths, tempos and pitches described in [the articulation support matrix](../tests/acid/acid_articulation_manual.md).
The full authored gate matrix passes on the checked profile; moving glide and
same-pitch glide each have their own measured length/tempo classes. Other
profiles, pitches and layouts are refused before mutation. Accent on a connected
slide chain is also refused. One-shot remains available as a separate playback
setting. Deterministic Renoise offline renders pass the listed gate, glide and
flat NOTE/TIE-accent cases; they do not establish current-desktop soundcard-loopback
or hardware behavior. Manual transport stop/start, seek and Live Edit during
audio playback remain unverified. A semantic slide
request is not proof of envelope-continuous sample glide or TB-303 acoustic
fidelity. Remaining acceptance checks are in the
[articulation](../tests/acid/acid_articulation_manual.md) and
[loop verification](../tests/acid/acid_loop_manual.md) procedures.

Experimental one-shot gate rendering releases isolated notes halfway through
their step and tied runs halfway through their final held step. A following
REST releases at its own boundary. Gate and glide writes share a preflighted
operation plan; conflicting OFF and glide commands are refused. The one-shot
tail, fresh-successor and Repeat REST-seam matrix passes deterministic offline
renders on the checked profile at 90/120/150 BPM. See the
[gate verification procedure](../tests/acid/acid_gate_manual.md).

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
