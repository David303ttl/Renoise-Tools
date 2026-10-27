#requires -Version 7.0

# Validates planning fixtures against a small independent semantic oracle. This
# checks authored expectations only; it does not load ACID or validate runtime playback.

$ErrorActionPreference = 'Stop'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\loop_cases.json'
$oracle = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable

function ConvertTo-Comparable($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($value.Keys | Sort-Object)) { $ordered[$key] = ConvertTo-Comparable $value[$key] }
        return $ordered
    }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $value) { $items.Add((ConvertTo-Comparable $item)) }
        return ,$items.ToArray()
    }
    return $value
}

function Assert-Equal($actual, $expected, [string]$context) {
    $actualJson = ConvertTo-Json -InputObject (ConvertTo-Comparable @($actual)) -Compress -Depth 32
    $expectedJson = ConvertTo-Json -InputObject (ConvertTo-Comparable @($expected)) -Compress -Depth 32
    if ($actualJson -cne $expectedJson) {
        throw "$context`: expected $expectedJson, got $actualJson"
    }
}

function Assert-True([bool]$condition, [string]$context) {
    if (-not $condition) { throw $context }
}

function Get-ExpectedCycle($case, [int]$cycle, $incomingState) {
    $pitchLength = [int]$case.pitch_length
    $time = @($case.time)
    $pitches = [System.Collections.Generic.List[object]]::new()
    foreach ($pitch in @($case.pitches)) { $pitches.Add($pitch) }
    while ($pitches.Count -lt $pitchLength) { $pitches.Add(@{ note = 36; slide = $false }) }
    Assert-True ($pitchLength -ge 1 -and $pitchLength -le $oracle.capacity) "$($case.id): invalid pitch_length"
    Assert-True ($time.Count -eq $case.length) "$($case.id): TIME count differs from length"
    Assert-True ($pitches.Count -ge $pitchLength) "$($case.id): active PITCH span exceeds normalized memory"

    $noteIndices = [System.Collections.Generic.List[int]]::new()
    $noteValues = [System.Collections.Generic.List[int]]::new()
    $transitions = [System.Collections.Generic.List[string]]::new()
    $ties = [System.Collections.Generic.List[object]]::new()
    $releases = [System.Collections.Generic.List[bool]]::new()
    $active = if ($null -eq $incomingState) { $false } else { [bool]$incomingState.active }
    $voice = if ($null -eq $incomingState) { $null } else { $incomingState.voice }
    $cursor = 1
    for ($step = 0; $step -lt $time.Count; $step++) {
        switch -CaseSensitive ($time[$step]) {
            'N' {
                $pitch = $pitches[$cursor - 1]
                $index = $cursor
                $cursor = ($cursor % $pitchLength) + 1
                $noteIndices.Add($index)
                $noteValues.Add([int]$pitch.note)
                $transition = if (-not $active) { 'attack' } elseif ($voice.slide -eq $true) { 'slide' } else { 'retrigger' }
                $transitions.Add($transition)
                $active = $true
                $voice = @{ note = [int]$pitch.note; pitch_index = $index; slide = ($pitch.slide -eq $true) }
            }
            'T' {
                if ($active) { $ties.Add([int]$voice.note) } else { $ties.Add($null) }
            }
            'R' {
                $releases.Add([bool]$active)
                $active = $false
                $voice = $null
            }
            default { throw "$($case.id): unsupported TIME command '$($time[$step])'" }
        }
    }

    # The source cursor is reset at each cycle boundary; the sounding voice is retained.
    $expected = $case.expected[$cycle]
    Assert-Equal $noteIndices.ToArray() $expected.note_pitch_indices "$($case.id) cycle $($cycle + 1) pitch indices"
    Assert-Equal $noteValues.ToArray() $expected.note_values "$($case.id) cycle $($cycle + 1) note values"
    Assert-Equal $transitions.ToArray() $expected.note_transitions "$($case.id) cycle $($cycle + 1) transitions"
    Assert-Equal $ties.ToArray() $expected.tie_notes "$($case.id) cycle $($cycle + 1) ties"
    Assert-Equal $releases.ToArray() $expected.rest_releases "$($case.id) cycle $($cycle + 1) releases"
    Assert-Equal $voice $expected.exit_voice "$($case.id) cycle $($cycle + 1) exit voice"
    Assert-True ($cursor -eq $expected.exit_next_pitch) "$($case.id) cycle $($cycle + 1): exit cursor expected $($expected.exit_next_pitch), got $cursor"

    # Return the exit state for the next traversal, preserving voice identity.
    return @{ active = $active; voice = $voice }
}

Assert-True ($oracle.format -eq 'ACID-LOOP-ORACLE-1') 'Unexpected fixture format'
Assert-True ($oracle.status -match 'native playback unverified') 'Fixture must not claim verified native playback'
Assert-True ($oracle.cycles -ge 3) 'Oracle must cover three cycles'
Assert-True ($oracle.index_base -eq 1) 'PITCH indices must be one-based'
Assert-True ($oracle.capacity -eq 64) 'PITCH memory capacity must remain 64'

foreach ($case in $oracle.cases) {
    Assert-True ($case.expected.Count -eq $oracle.cycles) "$($case.id): wrong cycle count"
    $state = $null
    for ($cycle = 0; $cycle -lt $oracle.cycles; $cycle++) {
        $state = Get-ExpectedCycle $case $cycle $state
    }
}

$boundary = $oracle.boundary_family
Assert-True ($boundary.source_generator.pitch_length -eq $oracle.capacity) 'Boundary family must use all 64 stored pitches'
Assert-True ($boundary.source_generator.note_formula -eq 'note = 24 + ((pitch_index - 1) modulo 37)') 'Boundary formula must stay within the editable three-octave range'
Assert-True ($boundary.length_cases.Count -eq 8) 'Boundary family must cover eight acceptance lengths'
$requiredLengths = @(1,16,17,32,33,48,49,64)
foreach ($lengthCase in $boundary.length_cases) {
    $length = [int]$lengthCase.length
    Assert-True ($requiredLengths -contains $length) "Unexpected boundary length $length"
    Assert-True ($lengthCase.first_transitions.Count -eq $oracle.cycles) "Length $($length): wrong cycle count"
    $nonNotes = @($boundary.source_generator.time_overrides.Keys | Where-Object { [int]$_ -le $length }).Count
    Assert-True ($lengthCase.note_count -eq ($length - $nonNotes)) "Length $($length): malformed note count"
    Assert-True ($lengthCase.exit_next_pitch -eq ($lengthCase.note_count + 1)) "Length $($length): exit cursor inconsistent with NOTE count"

    $firstTransitions = [System.Collections.Generic.List[string]]::new()
    $checkpointByStep = @{}
    foreach ($checkpoint in $boundary.expected_checkpoint_each_cycle) { $checkpointByStep[[string]$checkpoint.step] = $checkpoint }
    $active = $false
    $voice = $null
    for ($cycle = 0; $cycle -lt $oracle.cycles; $cycle++) {
        $cursor = 1
        $firstNoteTransition = $null
        for ($step = 1; $step -le $length; $step++) {
            $kind = if ($boundary.source_generator.time_overrides.ContainsKey([string]$step)) { $boundary.source_generator.time_overrides[[string]$step] } else { $boundary.source_generator.time_default }
            switch -CaseSensitive ($kind) {
                'N' {
                    $index = $cursor
                    $cursor = ($cursor % $oracle.capacity) + 1
                    $slide = @($boundary.source_generator.slide_pitch_indices) -contains $index
                    $transition = if (-not $active) { 'attack' } elseif ($voice.slide) { 'slide' } else { 'retrigger' }
                    if ($null -eq $firstNoteTransition) { $firstNoteTransition = $transition }
                    $voice = @{ note = 24 + (($index - 1) % 37); pitch_index = $index; slide = $slide }
                    $active = $true
                }
                'T' { }
                'R' {
                    $releasedNote = if ($active) { $voice.note } else { $null }
                    $active = $false
                    $voice = $null
                }
                default { throw "Boundary generator emitted unsupported TIME command '$kind'" }
            }
            if ($checkpointByStep.ContainsKey([string]$step)) {
                $checkpoint = $checkpointByStep[[string]$step]
                if ($step -le $length) {
                    if ($checkpoint.kind -eq 'note') {
                        Assert-True ($voice.pitch_index -eq $checkpoint.pitch_index -and $voice.note -eq $checkpoint.note -and $transition -eq $checkpoint.transition) "Length $length step $($step): NOTE checkpoint mismatch"
                    } elseif ($checkpoint.kind -eq 'tie') {
                        Assert-True ($active -and $voice.pitch_index -eq $checkpoint.voice_pitch_index -and $voice.note -eq $checkpoint.voice_note) "Length $length step $($step): TIE checkpoint mismatch"
                        $nextStep = if ($step -eq $length) { 1 } else { $step + 1 }
                        $nextKind = if ($boundary.source_generator.time_overrides.ContainsKey([string]$nextStep)) { $boundary.source_generator.time_overrides[[string]$nextStep] } else { $boundary.source_generator.time_default }
                        $holdIntent = $voice.slide -or $nextKind -eq 'T'
                        Assert-True ($checkpoint.holds -eq $active -and $checkpoint.hold_intent -eq $holdIntent) "Length $length step $($step): TIE hold expectation mismatch"
                    } elseif ($checkpoint.kind -eq 'rest') {
                        Assert-True (-not $active -and $checkpoint.releases -and -not $checkpoint.hold_intent) "Length $length step $($step): REST checkpoint mismatch"
                        Assert-True ($releasedNote -eq $checkpoint.released_note) "Length $length step $($step): released pitch mismatch"
                    }
                }
            }
        }
        $firstTransitions.Add($firstNoteTransition)
    }
    Assert-Equal $firstTransitions.ToArray() $lengthCase.first_transitions "Length $length first transitions"
    Assert-Equal $voice $lengthCase.exit_voice "Length $length exit voice"
    Assert-True ($cursor -eq $lengthCase.exit_next_pitch) "Length $length exit cursor mismatch"
}

foreach ($entry in $oracle.entry_cases) {
    if ($entry.operation -eq 'enter_time') {
        Assert-True ($entry.input_time.Count -eq $entry.length -and $entry.expected_time.Count -eq $entry.length) "$($entry.id): TIME length mismatch"
        $normalized = @($entry.input_time)
        if ($normalized[0] -eq 'T') { $normalized[0] = 'N' }
        Assert-Equal $normalized $entry.expected_time "$($entry.id) entered TIME normalization"
        Assert-True ($entry.expected_time[0] -eq 'N') "$($entry.id): entered leading TIE must normalize to NOTE"
        Assert-True ($entry.expected_note_pitch_indices_each_cycle[0] -eq 1) "$($entry.id): normalized NOTE must consume P01"
        Assert-True ($entry.expected_first_transitions.Count -eq $oracle.cycles) "$($entry.id): wrong first-transition cycle count"

        $entryPitchLength = [int]$entry.pitch_length
        $entryPitches = [System.Collections.Generic.List[object]]::new()
        foreach ($pitch in @($entry.pitches)) { $entryPitches.Add($pitch) }
        while ($entryPitches.Count -lt $entryPitchLength) { $entryPitches.Add(@{ note = 36; slide = $false }) }
        $computedFirstTransitions = [System.Collections.Generic.List[string]]::new()
        $active = $false
        $voice = $null
        for ($cycle = 0; $cycle -lt $oracle.cycles; $cycle++) {
            $pitchCursor = 1
            $firstTransition = $null
            $consumed = [System.Collections.Generic.List[int]]::new()
            $values = [System.Collections.Generic.List[int]]::new()
            foreach ($command in $entry.expected_time) {
                if ($command -eq 'N') {
                    $pitch = $entryPitches[$pitchCursor - 1]
                    $consumed.Add($pitchCursor)
                    $values.Add([int]$pitch.note)
                    $transition = if (-not $active) { 'attack' } elseif ($voice.slide -eq $true) { 'slide' } else { 'retrigger' }
                    if ($null -eq $firstTransition) { $firstTransition = $transition }
                    $active = $true
                    $voice = @{ note = [int]$pitch.note; pitch_index = $pitchCursor; slide = ($pitch.slide -eq $true) }
                    $pitchCursor = ($pitchCursor % $entryPitchLength) + 1
                } elseif ($command -eq 'R') {
                    $active = $false
                    $voice = $null
                }
            }
            $computedFirstTransitions.Add($firstTransition)
            Assert-Equal $consumed.ToArray() $entry.expected_note_pitch_indices_each_cycle "$($entry.id) cycle $($cycle + 1) normalized pitch consumption"
            Assert-Equal $values.ToArray() $entry.expected_note_values_each_cycle "$($entry.id) cycle $($cycle + 1) normalized note values"
        }
        Assert-Equal $computedFirstTransitions.ToArray() $entry.expected_first_transitions "$($entry.id) first transitions"
    }
    if ($entry.operation -eq 'validate_source') {
        Assert-True ($entry.expected_error -eq 'leading_tie' -and $entry.source_unchanged -and
            $entry.input_time[0] -eq 'T') 'Raw leading TIE refusal must preserve source'
    }
}

Assert-True (@($oracle.entry_cases | Where-Object operation -eq 'enter_time').Count -eq 1) 'Missing shared leading-TIE entry normalization case'
Assert-True (@($oracle.entry_cases | Where-Object operation -eq 'validate_source').Count -eq 1) 'Missing shared raw leading-TIE validation case'
Assert-True ($oracle.cutover_cases.Count -ge 2) 'Missing cutover fixtures'
$sourceCutover = @($oracle.cutover_cases | Where-Object operation -eq 'load_source')
Assert-True ($sourceCutover.Count -eq 1 -and $sourceCutover.source_format -eq 'ACID-PITCH-TIME-2') 'Missing unsupported development-format fixture'
Assert-True ($sourceCutover.expected_error -eq 'unsupported_source_format' -and $sourceCutover.imports -eq 0 -and $sourceCutover.writes_on_read -eq 0) 'Unsupported source read must refuse without importing or writing'
$sealCutover = @($oracle.cutover_cases | Where-Object operation -eq 'check_ownership')
Assert-True ($sealCutover.Count -eq 1 -and $sealCutover.expected_status -eq 'foreign' -and -not $sealCutover.adoption_allowed) 'Earlier development seal must not confer ownership or permit adoption'

Write-Host "ACID fixture oracle checks passed ($($oracle.cases.Count) semantic cases, $($boundary.length_cases.Count) boundary lengths)."
