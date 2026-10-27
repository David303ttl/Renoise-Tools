# ACID slide and articulation checks

The three-mode comparison procedure is retired. ACID now has one semantic
renderer; SLIDE is source intent and Repeat/Play Once is the phrase output
policy. Use a disposable Renoise song and follow the
[M3.5-S checklist](acid_m35_s_manual.md).

For a target comparison, create one source with NOTE, TIE, REST and outgoing
SLIDE/ACCENT flags, then generate it with the automatic renderer. Inspect the
ordered NOTE/OFF/effect cells and record any approximation shown by ACID.
Capture sample, plugin and MIDI targets separately. Phrase cells establish
structural output only; they do not establish pitch continuity, envelope
behavior or analog fidelity.

The former Baseline/Retrigger/Selective Slide mode captures are historical M3
evidence. The removed mode-specific spec is replaced by
`acid_articulation_semantics_spec.lua` and current writer integration checks.
