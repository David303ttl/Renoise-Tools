#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('ACID')][string]$Tool = 'ACID',
    [ValidateSet('Native','Keyboard','All')][string]$Suite = 'Native',
    [string]$Scenario,
    [string]$AcceptanceCase,
    [string]$MidiOutputDevice,
    [string]$AudioInputDevice,
    [ValidateSet(44100,48000,96000)][int]$AudioSampleRate = 48000,
    [string]$ProductionCheckpoint,
    [ValidateSet('Warm','Detailed')][string]$AcceptanceProfile = 'Warm',
    [string]$RenoiseExe,
    [int]$RenoiseProcessId = 0,
    [string]$TestEnvironment,
    [string]$ToolsDirectory,
    [ValidateRange(5,600)][int]$StartupTimeoutSeconds = 90,
    [ValidateRange(1,300)][int]$CommandTimeoutSeconds = 30,
    [switch]$ApproveDisposableSong,
    [switch]$Install,
    [switch]$VerifyScenarioOrder,
    [switch]$AllowKeyboardFocusActivation
)

class RenoiseRunnerAssertionException : System.Exception {
    RenoiseRunnerAssertionException([string]$message) : base($message) {}
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'tests/renoise/runner.psm1') -Force
$runnerProcessGracefulShutdownMilliseconds = 10000
$runnerProcessForcedShutdownMilliseconds = 5000
$runnerProcessIdentityWaitMilliseconds = 5000
$coldRegenerationFixtureName = 'acceptance-cold-regenerated.xrns'
$independentFixtureInstrumentCount = 10
$independentPrimaryPhraseCount = 2
$independentForeignSentinelCount = 1
$artifactId = [guid]::NewGuid().ToString('N')
$repoTemp = Join-Path $repoRoot 'tmp'
$null = New-Item -ItemType Directory -Path $repoTemp -Force
$artifactRoot = Join-Path $repoTemp ('interactive-' + $artifactId)
$devOutputName = 'tmp/acid-dev-' + $artifactId
$devOutput = Join-Path $repoRoot $devOutputName.Replace('/', [IO.Path]::DirectorySeparatorChar)
$devToolName = 'com.david303ttl.ACID.xrnx'
$sessionName = 'acid-test-session.conf'
$startedProcess = $null
$startedIdentity = $null
$selectedIdentity = $null
$installedToolPath = $null
$backupToolPath = $null
$localBackupToolPath = $null
$sessionTargetPath = $null
$sessionBackupPath = $null
$localBackupSessionPath = $null
$deploymentStageRoot = $null
$deploymentStageToolPath = $null
$deploymentStageSessionPath = $null
$deploymentStageToolHash = $null
$deploymentStageSessionHash = $null
$fixturesSourcePath = $null
$installedFixturesPath = $null
$fixturesBackupPath = $null
$localBackupFixturesPath = $null
$deploymentStageFixturesPath = $null
$deploymentStageFixturesHash = $null
$installedFixturesHash = $null
$installedDirectoryHash = $null
$installedSessionHash = $null
$fixturesDeployed = $false
$deploymentStarted = $false
$safeToRestore = $false
$driverMayBeLoaded = $false
$startedProcessForceStopped = $false
$startedProcessClosed = $false
$toolDeployed = $false
$sessionDeployed = $false
$exeVersionTriplet = $null
$session = $null
$keyboardConfiguration = $null
$keyboardExecutable = $null
$keyboardHelperPath = Join-Path $repoRoot 'tests/renoise/keyboard/send_keys.ahk'
$activeSuite = if ($Suite -eq 'Keyboard') { 'Keyboard' } else { 'Native' }
$lastExpected = 'Runner preflight completes without changing developer-owned Renoise state'
$lastActual = $null
$lastDiff = $null
$productionPlaybackSummary = $null
$inventoryDiff = $null
$report = [ordered]@{
    schema_version = 1
    run_id = $artifactId
    tool = $Tool
    suite = $Suite
    scenario = if ($Scenario) { $Scenario } else { 'all' }
    status = 'ERROR'
    source_commit = $null
    host = $null
    tool_version = $null
    acceptance_profile = $null
    document_epoch = $null
    elapsed_ms = 0
    operation_trace = @()
    scenarios = @()
    keyboard = $null
    scenario_order_acceptance = $null
    error = $null
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$transportOnly = $Suite -eq 'Keyboard' -or ($Scenario -ceq 'transport' -and -not $AcceptanceCase)
$productionSessionAcceptance = $AcceptanceCase -cin @('production-session-8x8','production-stress-16x8')
$revisionLiveUndoAcceptance = $AcceptanceCase -ceq 'revision-live-undo'
$revisionUndoAcceptance = $AcceptanceCase -cin @('revision-undo','revision-live-undo')
$metadataUndoAcceptance = $AcceptanceCase -ceq 'metadata-undo'
$metadataRecoveryAcceptance = $AcceptanceCase -ceq 'metadata-recovery'

function Add-Trace {
    param([string]$Operation, [string]$Status, [object]$Details = $null)
    $script:report.operation_trace += [pscustomobject]@{
        operation = $Operation
        status = $Status
        elapsed_ms = $script:clock.ElapsedMilliseconds
        details = $Details
    }
}

function Read-ScenarioOrderSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    $snapshot = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 64
    if ($snapshot -isnot [Collections.IDictionary] -or -not $snapshot.Contains('document_epoch')) {
        throw "Scenario snapshot lacks top-level document_epoch metadata: $Path"
    }
    $epoch = $snapshot['document_epoch']
    [void]$snapshot.Remove('document_epoch')
    $canonical = ConvertTo-AcidCanonicalJson $snapshot
    $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
    return [pscustomobject]@{ DocumentEpoch = $epoch; Canonical = $canonical; Sha256 = $sha256 }
}

function Set-UserOnlyFileAcl {
    param([Parameter(Mandatory)][string]$Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.User) { throw 'Could not identify the current Windows user for the session-file ACL.' }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity.User,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-VersionTriplet {
    param([Parameter(Mandatory)][string]$Value)
    $match = [regex]::Match($Value, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
    if (-not $match.Success) { throw "Could not resolve Renoise version from '$Value'." }
    return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Assert-RunnerProcess {
    if ($null -ne $script:startedIdentity) { Assert-RenoiseProcessIdentity -Identity $script:startedIdentity }
    elseif ($null -ne $script:selectedIdentity) { Assert-RenoiseProcessIdentity -Identity $script:selectedIdentity }
}

function Stop-RunnerOwnedProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][pscustomobject]$Identity,
        [Parameter(Mandatory)][string]$Context
    )
    $Process.Refresh()
    if ($Process.HasExited) { return $false }
    Assert-RenoiseProcessIdentity -Identity $Identity
    [void]$Process.CloseMainWindow()
    if (-not $Process.WaitForExit($script:runnerProcessGracefulShutdownMilliseconds)) {
        Assert-RenoiseProcessIdentity -Identity $Identity
        Stop-Process -Id $Identity.Id -Force -ErrorAction Stop
        if (-not $Process.WaitForExit($script:runnerProcessForcedShutdownMilliseconds)) {
            throw "Runner-launched Renoise did not terminate after identity-checked $Context cleanup."
        }
        Add-Trace -Operation 'process.force_stop' -Status 'PASS' -Details @{
            runner_launched_process_only = $true
            disposable_song_approved = $true
            context = $Context
            after_error = $Context -ceq 'after-error'
        }
        return $true
    }
    return $false
}

function Start-RunnerOwnedProcess {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SongPath)
    $arguments = @()
    if ($SongPath) {
        $songItem = Get-Item -LiteralPath $SongPath -Force -ErrorAction Stop
        if ($songItem.PSIsContainer -or ($songItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Cold-process input song is not a plain file.'
        }
        $arguments = @('"' + $songItem.FullName + '"')
    }
    $process = if ($arguments.Count -gt 0) {
        Start-Process -FilePath $script:resolvedExe -ArgumentList $arguments -WindowStyle Normal -PassThru
    } else {
        Start-Process -FilePath $script:resolvedExe -WindowStyle Normal -PassThru
    }
    $script:startedProcess = $process
    $script:startedIdentity = $null
    $script:startedProcessClosed = $false
    $script:safeToRestore = $false
    $startedAt = $process.StartTime.ToUniversalTime()
    $identity = Get-RenoiseProcessIdentity -Id $process.Id -WaitMilliseconds $script:runnerProcessIdentityWaitMilliseconds
    if (-not [string]::Equals($identity.Path, $script:resolvedExe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Started Renoise process does not match the verified executable.'
    }
    if ($identity.StartTimeUtc -ne $startedAt) {
        throw 'Started Renoise process changed identity before metadata became available.'
    }
    return [pscustomobject]@{ Process = $process; Identity = $identity }
}

function Invoke-ColdProcessAcceptance {
    param(
        [Parameter(Mandatory)][string]$SongPath,
        [Parameter(Mandatory)][string]$Case,
        $ExpectedBaseline,
        [int]$ExpectedOldId,
        [int]$ExpectedTargetId,
        [string]$ExpectedFixture,
        [string]$Stage,
        [string]$MidiOutputDevice
    )
    $oldIdentity = $script:processIdentity
    $processCheck = { Assert-RenoiseProcessIdentity -Identity $script:processIdentity }
    $null = Stop-RenoiseDriver -Client $script:client -Session $script:session `
        -SessionPath $script:sessionTargetPath -TimeoutSeconds $script:CommandTimeoutSeconds -ProcessCheck $processCheck
    Add-Trace -Operation 'driver.shutdown' -Status 'PASS' -Details @{ cold_process = $true; pid = $oldIdentity.Id }
    $script:client.Dispose()
    $script:client = $null
    $forceStopped = Stop-RunnerOwnedProcess -Process $script:startedProcess -Identity $oldIdentity -Context 'cold-process'
    $script:startedProcessForceStopped = $script:startedProcessForceStopped -or $forceStopped
    $script:startedProcessClosed = $true
    $script:safeToRestore = $true
    Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ cold_process = $true; pid = $oldIdentity.Id; force_stopped = $forceStopped }

    $script:safeToRestore = $false
    $launched = Start-RunnerOwnedProcess -SongPath $SongPath
    $script:startedProcess = $launched.Process
    $script:startedIdentity = $launched.Identity
    $script:processIdentity = $launched.Identity
    $script:startedProcessClosed = $false
    $script:driverMayBeLoaded = $true
    $script:report.host.process_id = $launched.Identity.Id
    $script:report.host.process_start_time_utc = $launched.Identity.StartTimeUtc.ToString('o')
    $processCheck = { Assert-RenoiseProcessIdentity -Identity $script:processIdentity }
    Add-Trace -Operation 'process.cold_start' -Status 'PASS' -Details @{
        pid = $launched.Identity.Id
        start_time_utc = $launched.Identity.StartTimeUtc.ToString('o')
        previous_pid = $oldIdentity.Id
        song = [IO.Path]::GetFileName($SongPath)
    }
    $null = Get-Preflight -SelectedId $launched.Identity.Id
    $bootstrap = Invoke-RenoiseDriverBootstrap -Session $script:session -Identity $launched.Identity `
        -StartupTimeoutSeconds $script:StartupTimeoutSeconds -CommandTimeoutSeconds $script:CommandTimeoutSeconds `
        -ProcessCheck $processCheck
    $script:client = $bootstrap.Client
    Add-Trace -Operation 'driver.bootstrap' -Status 'PASS' -Details @{
        cold_process = $true; attempts = $bootstrap.Attempts; stages = @($bootstrap.AttemptDiagnostics)
    }
    if ($bootstrap.Ping.protocol_version -ne 1 -or $bootstrap.Ping.session -cne $script:session.Nonce) {
        throw [RenoiseRunnerAssertionException]::new('Cold-process authenticated handshake reported the wrong protocol or run nonce.')
    }
    $coldArguments = @{case=$Case}
    if ($Stage) { $coldArguments.stage=$Stage; $coldArguments.midi_output_device=$MidiOutputDevice }
    $result = Invoke-RenoiseDriverRequest -Client $script:client -Session $script:session `
        -Operation 'acid.acceptance.run' -Arguments $coldArguments `
        -TimeoutSeconds $(if ($Stage) { 3600 } else { [Math]::Max($script:CommandTimeoutSeconds, 180) }) -ProcessCheck $processCheck
    if ($result.case -cne $Case -or [string]$result.status -cne 'PASS') {
        throw [RenoiseRunnerAssertionException]::new("Cold-process acceptance '$Case' did not pass: $(ConvertTo-AcidCanonicalJson $result)")
    }
    if ($null -eq $ExpectedBaseline -or $null -eq $result.reopened_baseline -or
        (ConvertTo-AcidCanonicalJson $ExpectedBaseline) -cne (ConvertTo-AcidCanonicalJson $result.reopened_baseline)) {
        throw [RenoiseRunnerAssertionException]::new("Cold-process acceptance '$Case' changed the independently captured persisted baseline.")
    }
    if ($Stage) {
        if ($result.reopened_baseline -cne $ExpectedBaseline) {
            throw [RenoiseRunnerAssertionException]::new('Production cold baseline mismatch.')
        }
        Add-Trace -Operation "acceptance.$Case.$Stage" -Status 'PASS' -Details $result
        return $result
    }
    if ($Case -cin @('metadata-recovery-cold')) {
        $requiredPostcondition = if ($Case -ceq 'metadata-recovery-cold') { $result.owned_and_new_labels_exact } else { $result.recovered_generation_verified }
        if ($result.read_only_restore -ne $true -or $requiredPostcondition -ne $true) {
            throw [RenoiseRunnerAssertionException]::new('Cold recovery-label acceptance omitted required postconditions.')
        }
        $script:scenarioResults.Add([pscustomobject]@{
            name = "acceptance.$Case"; suite = 'Native'; status = 'PASS'
            expected = 'Fresh-process restoration preserves the exact persisted baseline and case-specific label/draft postconditions'
            actual = ConvertTo-AcidCanonicalJson $result; diff = $null
        })
        Add-Trace -Operation "acceptance.$Case" -Status 'PASS' -Details $result
        return $result
    }
    $targetRevisionMatches = if ($Case -ceq 'cold-reopen-regenerate') {
        $result.previous_target_id -eq $ExpectedTargetId -and $null -ne $result.target_id -and $result.target_id -ne $ExpectedTargetId
    } else { $result.target_id -eq $ExpectedTargetId }
    if ($result.old_id -ne $ExpectedOldId -or -not $targetRevisionMatches) {
        throw [RenoiseRunnerAssertionException]::new("Cold-process acceptance '$Case' did not preserve the original identity and expected source revision transition.")
    }
    Add-Trace -Operation 'acceptance.persisted_baseline' -Status 'PASS' -Details @{
        case = $Case; expected = $ExpectedBaseline; actual = $result.reopened_baseline
    }
    if ($ExpectedFixture -and $result.roundtrip_fixture -cne $ExpectedFixture) {
        throw [RenoiseRunnerAssertionException]::new("Cold-process acceptance '$Case' returned an unexpected saved fixture name.")
    }
    $script:scenarioResults.Add([pscustomobject]@{
        name = "acceptance.$Case"
        suite = 'Native'
        status = 'PASS'
        expected = if ($ExpectedFixture) { "Cold reopened song passes read-only checks, then regenerates and saves '$ExpectedFixture'" } else { 'Cold reopened regenerated song passes read-only association checks' }
        actual = ConvertTo-AcidCanonicalJson $result
        diff = $null
    })
    Add-Trace -Operation "acceptance.$Case" -Status 'PASS' -Details $result
    return $result
}

function Save-ProductionFixtureArtifacts {
    if (-not $productionSessionAcceptance -or -not $fixturesDeployed -or
        -not (Test-Path -LiteralPath $installedFixturesPath)) { return }
    Assert-DirectoryHasNoReparsePoints -Path $installedFixturesPath
    $generatedNames = @('acceptance-production.xrns','acceptance-production-baseline.json','acceptance-production-state.json')
    $sourceFiles = @(Get-ChildItem -LiteralPath $fixturesSourcePath -File)
    $allowedNames = @($sourceFiles.Name) + $generatedNames
    foreach ($entry in @(Get-ChildItem -LiteralPath $installedFixturesPath -Force)) {
        if ($entry.PSIsContainer -or $entry.Name -cnotin $allowedNames) {
            throw 'Production acceptance changed an unexpected fixture path.'
        }
    }
    foreach ($source in $sourceFiles) {
        $installed = Join-Path $installedFixturesPath $source.Name
        if (-not (Test-Path -LiteralPath $installed -PathType Leaf) -or
            (Get-FileHash -LiteralPath $installed).Hash -cne (Get-FileHash -LiteralPath $source.FullName).Hash) {
            throw 'Production acceptance changed a staged source fixture.'
        }
    }
    foreach ($name in $generatedNames) {
        $generated = Join-Path $installedFixturesPath $name
        if (Test-Path -LiteralPath $generated -PathType Leaf) {
            Copy-Item -LiteralPath $generated -Destination (Join-Path $artifactRoot $name)
        }
    }
    $script:installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
}

function Test-ProductionAudioSignal {
    param([double]$Rms, [double]$MutedRms)
    # Match the audio oracle's -60 dBFS silence floor and 3 dB sustain margin.
    return [double]::IsFinite($Rms) -and [double]::IsFinite($MutedRms) -and
        $MutedRms -ge 0 -and $Rms -gt 0.001 -and $Rms -gt $MutedRms * [Math]::Sqrt(2)
}

function Invoke-ProductionAudioCapture {
    Import-Module (Join-Path $repoRoot 'tests/acid/audio_analyzer.psm1') -Force
    $ffmpeg = (Get-Command ffmpeg -CommandType Application -ErrorAction Stop).Source
    $captures = [Collections.Generic.List[object]]::new()
    $silenceRms = $null
    try {
        foreach ($kind in @('silence','sample','vst','all')) {
            $ready = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
                -Arguments @{case=$AcceptanceCase;stage="playback-$kind";midi_output_device=$MidiOutputDevice} `
                -TimeoutSeconds 180 -ProcessCheck $processCheck
            if ($ready.status -cne 'PASS' -or $ready.playing -ne $true) { throw 'Production playback route did not start.' }
            $wavePath = Join-Path $artifactRoot "playback-$kind.wav"
            $logPath = Join-Path $artifactRoot "playback-$kind.log"
            & $ffmpeg -hide_banner -nostdin -y -f dshow -sample_rate $AudioSampleRate -sample_size 16 -channels 2 `
                -i "audio=$AudioInputDevice" -t 16 -c:a pcm_s16le $wavePath *> $logPath
            if ($LASTEXITCODE -ne 0) { throw "Audio capture failed; see playback-$kind.log." }
            & $processCheck
            $audio = Read-ArticulationWav $wavePath
            $rms = [Math]::Max((Get-SampleRms $audio.Left $audio.SampleRate 0 $audio.DurationMs),
                (Get-SampleRms $audio.Right $audio.SampleRate 0 $audio.DurationMs))
            if ($kind -ceq 'silence') { $silenceRms = $rms }
            $captures.Add([pscustomobject]@{receiver=$kind;frames=$audio.FrameCount;sample_rate=$audio.SampleRate;
                rms=$rms;muted_rms=$silenceRms;sha256=$audio.Sha256;file="playback-$kind.wav"})
            $captures | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $artifactRoot 'audio-receipt.json') -Encoding utf8
            if ($kind -cne 'silence' -and -not (Test-ProductionAudioSignal -Rms $rms -MutedRms $silenceRms)) {
                throw "No $kind signal above the audio oracle's silence floor and muted loopback baseline."
            }
        }
    }
    finally {
        $null = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
            -Arguments @{case=$AcceptanceCase;stage='playback-stop';midi_output_device=$MidiOutputDevice} `
            -TimeoutSeconds 180 -ProcessCheck $processCheck
    }
    return @($captures)
}

function Invoke-ProductionMidiCapture {
    $ready = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
        -Arguments @{case=$AcceptanceCase;stage='playback-midi';midi_output_device=$MidiOutputDevice} `
        -TimeoutSeconds 180 -ProcessCheck $processCheck
    if ($ready.status -cne 'PASS' -or $ready.playing -ne $true) { throw 'Production MIDI playback did not start.' }
    Start-Sleep -Seconds 3
    $receipt = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
        -Arguments @{case=$AcceptanceCase;stage='playback-stop';midi_output_device=$MidiOutputDevice} `
        -TimeoutSeconds 180 -ProcessCheck $processCheck
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifactRoot 'midi-receipt.json') -Encoding utf8
    Add-Trace -Operation 'production.midi_capture' -Status $receipt.status -Details $receipt
    if ($receipt.status -cne 'PASS') { throw 'Production MIDI playback did not stop cleanly.' }
    foreach ($proof in $receipt.receiver_proofs) {
        if ($proof.note -ne $true -or $proof.off -ne $true -or $proof.center -ne $true -or $proof.bend -ne $true) {
            throw [RenoiseRunnerAssertionException]::new('A production MIDI receiver did not deliver the expected note/OFF/center/bend sequence.')
        }
    }
    if (@($receipt.receiver_proofs).Count -notin @(2,4)) { throw 'Production MIDI receiver evidence is incomplete.' }
    return $receipt
}

function Get-Preflight {
    param([int]$SelectedId)
    $configuration = [pscustomobject]@{
        RenoiseExe = $script:resolvedExe
        RenoiseProcessId = $SelectedId
        TemporaryDirectory = [IO.Path]::GetTempPath()
    }
    $result = Test-RenoiseHostPreflight -Configuration $configuration -Mode Safety
    if (-not $result.Passed) { throw "Renoise host preflight failed: $($result.Errors -join '; ')" }
    return $result
}


try {
    New-Item -ItemType Directory -Path $artifactRoot -ErrorAction Stop | Out-Null
    if ($Scenario -and $Suite -eq 'Keyboard') { throw '-Scenario is only supported with Native or All suites.' }
    if ($AcceptanceCase -and $AcceptanceCase -cnotin @('api-probe','integrity-observers','writer-recovery','editor-responsiveness','gui-redesign','gui-layout','gui-lifecycle','ownership-negatives','cold-reopen-regenerate','cold-reopen-verify','multi-instrument-workflow','selection-feasibility','direct-output-feasibility','source-undo-feasibility','revision-undo','revision-live-undo','production-latency-8x8','production-latency-16x8','production-session-8x8','production-stress-16x8','phrase-midi-delivery','persistence-failures','metadata-undo','metadata-recovery')) {
        throw "Unsupported native acceptance case '$AcceptanceCase'."
    }
    if ($metadataRecoveryAcceptance -and $RenoiseProcessId -gt 0) {
        throw 'Metadata recovery cold reopen requires a runner-owned process; omit -RenoiseProcessId.'
    }
    $productionLatency = $AcceptanceCase -cin @('production-latency-8x8','production-latency-16x8','production-session-8x8','production-stress-16x8','phrase-midi-delivery')
    if ($productionLatency -and $RenoiseProcessId -gt 0) {
        throw 'Production latency diagnostics require a runner-owned Renoise process; omit -RenoiseProcessId.'
    }
    if ($productionLatency -and ([string]::IsNullOrWhiteSpace($MidiOutputDevice) -or $MidiOutputDevice.Length -gt 256)) {
        throw 'Production latency diagnostics require -MidiOutputDevice with the exact approved MIDI output name (1-256 characters).'
    }
    if ($MidiOutputDevice -and -not $productionLatency) { throw '-MidiOutputDevice is only valid for production cases.' }
    if ($AudioInputDevice -and (-not $productionSessionAcceptance -or $AudioInputDevice.Length -gt 256 -or
        $AudioInputDevice -match '[\x00-\x1f]')) { throw '-AudioInputDevice requires a production session and an exact input device name.' }
    if ($ProductionCheckpoint -and -not $productionSessionAcceptance) { throw '-ProductionCheckpoint requires a production session case.' }
    $profileResolution = Resolve-AcidAcceptanceProfile -AcceptanceCase $AcceptanceCase `
        -Profile $AcceptanceProfile -Explicit:($PSBoundParameters.ContainsKey('AcceptanceProfile'))
    $profileApplies = $profileResolution.Applies
    if ($profileApplies) { $report.acceptance_profile = $profileResolution.Profile }
    if ($AcceptanceCase -and $Suite -ne 'Native') { throw '-AcceptanceCase requires -Suite Native.' }
    if ($AllowKeyboardFocusActivation -and $Suite -eq 'Native' -and -not ($revisionUndoAcceptance -or $metadataUndoAcceptance -or $metadataRecoveryAcceptance -or $productionSessionAcceptance)) {
        throw '-AllowKeyboardFocusActivation is only valid for Keyboard or All suites, except Native undo acceptance.'
    }
    if ($VerifyScenarioOrder -and $Suite -ne 'Native') {
        throw '-VerifyScenarioOrder requires -Suite Native.'
    }
    if ($VerifyScenarioOrder -and $Scenario) {
        throw '-VerifyScenarioOrder runs the complete scenario catalog; omit -Scenario.'
    }
    if ($env:OS -ne 'Windows_NT') { throw 'This runner currently supports Windows. Release tools run in Renoise independently of this script.' }
    $lastExpected = 'RenoiseProcessId is zero or identifies the exact developer-owned process'
    if ($RenoiseProcessId -lt 0) { throw 'RenoiseProcessId must be a positive process ID.' }
    $lastExpected = 'Developer approves replacing the open document with a disposable new song'
    if (-not $ApproveDisposableSong) { throw 'Pass -ApproveDisposableSong only after confirming the open Renoise document can be replaced by a new empty document for this run.' }

    Import-Module (Join-Path $repoRoot 'tests/renoise/host_preflight.psm1') -Force
    $scenarioDirectory = Join-Path $repoRoot 'tests/renoise/acid/scenarios'
    $selectedCatalogScenarios = @(if ($Suite -in @('Native','All')) {
        Get-AcidInteractiveScenarioSelection -Scenario $Scenario -Directory $scenarioDirectory
    })
    if ($VerifyScenarioOrder) {
        if ($selectedCatalogScenarios.Count -lt 2) {
            throw "-VerifyScenarioOrder requires at least two distinct catalog scenarios to reverse; found $($selectedCatalogScenarios.Count)."
        }
        $scenarioNames = @($selectedCatalogScenarios | ForEach-Object { [string]$_.name })
        $reverseScenarioNames = [string[]]@($scenarioNames)
        [Array]::Reverse($reverseScenarioNames)
        $report.scenario_order_acceptance = [ordered]@{
            status = 'RUNNING'
            scenario_count = $selectedCatalogScenarios.Count
            individual_order = $scenarioNames
            reverse_order = @($reverseScenarioNames)
            comparison = 'canonical snapshot values match after excluding only top-level document_epoch'
            excluded_snapshot_fields = @('document_epoch')
            comparisons = @()
            idle_settlements = @()
        }
    }
    $lastExpected = 'Requested scenario is registered for the selected suite'
    $environment = Import-RenoiseTestEnvironment -Path $TestEnvironment
    if ($Suite -in @('Keyboard','All')) {
        $activeSuite = 'Keyboard'
        $keyboardNegativeCases = [Collections.Generic.List[object]]::new()
        try {
            Get-AcidKeyboardConfiguration -Environment ([pscustomobject]@{ Keyboard = [ordered]@{} }) | Out-Null
            throw 'Keyboard mapping validation accepted an empty configuration.'
        }
        catch {
            if ($_.Exception.Message -notmatch 'Keyboard mapping is missing') { throw }
            $keyboardNegativeCases.Add([pscustomobject]@{ name = 'missing_mapping'; status = 'PASS'; input_sent = $false })
            Add-Trace -Operation 'keyboard.negative.missing_mapping' -Status 'PASS' -Details @{ input_sent = $false }
        }
        $report.keyboard = [ordered]@{
            status = 'RUNNING'
            shortcut = $null
            auto_hotkey_version = $null
            negative_cases = @($keyboardNegativeCases)
            journey = $null
        }
        $keyboardConfiguration = Get-AcidKeyboardConfiguration -Environment $environment
    if ($Suite -in @('Keyboard','All') -and -not $AllowKeyboardFocusActivation -and $RenoiseProcessId -eq 0) {
        throw 'Nonintrusive Keyboard runs require -RenoiseProcessId for an already-running Renoise instance. Starting Renoise may steal desktop focus. Use -AllowKeyboardFocusActivation only in a dedicated interactive Windows session, or run -Suite Native on your work desktop.'
    }
        $keyboardExecutable = Find-AutoHotkeyV2Executable -ConfiguredPath $keyboardConfiguration.AutoHotkeyPath
        if (-not (Test-Path -LiteralPath $keyboardHelperPath -PathType Leaf)) { throw "AutoHotkey helper does not exist: $keyboardHelperPath" }
        $emptyProcessCheck = {}
        $versionResult = Invoke-AcidKeyboardHelper -Executable $keyboardExecutable -HelperScript $keyboardHelperPath -Mode Version -ProcessCheck $emptyProcessCheck
        if ($versionResult.ExitCode -ne 0 -or $versionResult.StdOut -cnotmatch '^2\.\d+\.\d+$') {
            throw "AutoHotkey v2 is required; helper reported '$($versionResult.StdOut)' with exit code $($versionResult.ExitCode)."
        }
        $report.keyboard.shortcut = $keyboardConfiguration.ShowShortcut
        $report.keyboard.auto_hotkey_version = $versionResult.StdOut
        foreach ($selfTest in @(
            [pscustomobject]@{ Mode = 'SelfTestWrongPid'; Name = 'wrong_pid' }
        )) {
            $selfTestResult = Invoke-AcidKeyboardHelper -Executable $keyboardExecutable -HelperScript $keyboardHelperPath -Mode $selfTest.Mode -ProcessCheck $emptyProcessCheck
            if ($selfTestResult.ExitCode -ne 0 -or $selfTestResult.StdOut -notmatch '^PASS self-test ') {
                $selfTestError = "AutoHotkey '$($selfTest.Name)' guard self-test failed: $($selfTestResult.StdErr) $($selfTestResult.StdOut)"
                throw $selfTestError.Trim()
            }
            $keyboardNegativeCases.Add([pscustomobject]@{ name = $selfTest.Name; status = 'PASS'; input_sent = $false })
            $report.keyboard.negative_cases = @($keyboardNegativeCases)
            Add-Trace -Operation "keyboard.negative.$($selfTest.Name)" -Status 'PASS' -Details @{ input_sent = $false; output = $selfTestResult.StdOut }
        }
        $report.keyboard.negative_cases = @($keyboardNegativeCases)
        $activeSuite = if ($Suite -eq 'Keyboard') { 'Keyboard' } else { 'Native' }
    }
    elseif ($revisionUndoAcceptance -or $metadataUndoAcceptance -or $metadataRecoveryAcceptance -or $productionSessionAcceptance) {
        $keyboardConfiguration = Get-AcidKeyboardConfiguration -Environment $environment
        $keyboardExecutable = Find-AutoHotkeyV2Executable -ConfiguredPath $keyboardConfiguration.AutoHotkeyPath
        if (-not (Test-Path -LiteralPath $keyboardHelperPath -PathType Leaf)) { throw "AutoHotkey helper does not exist: $keyboardHelperPath" }
        $emptyProcessCheck = {}
        $versionResult = Invoke-AcidKeyboardHelper -Executable $keyboardExecutable -HelperScript $keyboardHelperPath -Mode Version -ProcessCheck $emptyProcessCheck
        if ($versionResult.ExitCode -ne 0 -or $versionResult.StdOut -cnotmatch '^2\.\d+\.\d+$') {
            throw "AutoHotkey v2 is required; helper reported '$($versionResult.StdOut)' with exit code $($versionResult.ExitCode)."
        }
        Add-Trace -Operation 'keyboard.callback_configuration' -Status 'PASS' -Details @{ auto_hotkey_version = $versionResult.StdOut; keys = '{Enter}' }
    }
    $environmentExe = if ($environment.PSObject.Properties['RenoiseExe']) { [string]$environment.RenoiseExe } else { '' }
    if ($RenoiseExe -and $environmentExe -and
        -not [string]::Equals([IO.Path]::GetFullPath($RenoiseExe), [IO.Path]::GetFullPath($environmentExe), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RenoiseExe conflicts with the TestEnvironment RenoiseExe value.'
    }
    $configuredExe = if ($RenoiseExe) { $RenoiseExe } elseif ($environmentExe) { $environmentExe } else { '' }
    if ($RenoiseProcessId -gt 0 -and -not $configuredExe) {
        $selectedIdentity = Get-RenoiseProcessIdentity -Id $RenoiseProcessId
        $configuredExe = $selectedIdentity.Path
    }
    $script:resolvedExe = Get-RenoiseExecutable -ConfiguredPath $configuredExe
    if ($RenoiseProcessId -gt 0 -and -not $selectedIdentity) { $selectedIdentity = Get-RenoiseProcessIdentity -Id $RenoiseProcessId }
    $preflight = Get-Preflight -SelectedId $RenoiseProcessId
    if ($selectedIdentity) { Assert-RenoiseProcessIdentity -Identity $selectedIdentity }
    Add-Trace -Operation 'host.preflight' -Status 'PASS' -Details @{ selected_process_id = $RenoiseProcessId; target_verified = $true }

    $sourceCommit = & git -C $repoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $report.source_commit = [string]$sourceCommit }
    $exeInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($script:resolvedExe)
    $toolVersion = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'com.david303ttl.ACID.xrnx/manifest.xml') -Raw)
    $report.tool_version = [string]$toolVersion.RenoiseScriptingTool.Version
    $report.host = [ordered]@{
        renoise_version = [string]$exeInfo.ProductVersion
        executable_sha256 = (Get-FileHash -LiteralPath $script:resolvedExe -Algorithm SHA256).Hash.ToLowerInvariant()
        process_id = $RenoiseProcessId
    }

    if ($transportOnly) {
        & (Join-Path $repoRoot 'scripts/package_dev.ps1') -Tool ACID -OutputDirectory $devOutputName -TransportOnly | Out-Null
    }
    else {
        & (Join-Path $repoRoot 'scripts/package_dev.ps1') -Tool ACID -OutputDirectory $devOutputName | Out-Null
    }
    Add-Trace -Operation 'bundle.build' -Status 'PASS' -Details @{ output = $devOutputName }
    $devToolPath = Join-Path $devOutput $devToolName
    $sessionSourcePath = Join-Path $devOutput $sessionName
    if ($transportOnly) {
        $fixturesSourcePath = $null
    }
    else {
        $fixturesSourcePath = Join-Path $devOutput 'fixtures'
        if (-not (Test-Path -LiteralPath $fixturesSourcePath -PathType Container)) {
            throw 'Development bundle did not stage the native fixtures directory.'
        }
        $stagedFixtureCount = Assert-AcidScenarioFixtures -Directory $fixturesSourcePath -Scenarios $selectedCatalogScenarios
        Add-Trace -Operation 'fixture.preflight' -Status 'PASS' -Details @{ selected_scenarios = @($selectedCatalogScenarios | ForEach-Object { $_.name }); staged_fixture_count = $stagedFixtureCount }
    }
    $session = Get-RenoiseSessionConfig -Path $sessionSourcePath

    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $exeVersionTriplet = Get-VersionTriplet -Value ([string]$exeInfo.ProductVersion)
    $renoiseVersion = $exeVersionTriplet.ToString(3)
    $toolsPath = if ($ToolsDirectory) { [IO.Path]::GetFullPath($ToolsDirectory) } else { Join-Path $appData "Renoise/V$renoiseVersion/Scripts/Tools" }
    $installedToolPath = Join-Path $toolsPath $devToolName
    $sessionTargetPath = Join-Path $toolsPath $sessionName
    $installedFixturesPath = if ($transportOnly) { $null } else { Join-Path $toolsPath 'fixtures' }
    $lastExpected = 'Explicit install consent and a verified restoration path are present'
    if (-not $Install) { throw "ACID installation is required to load this development bundle. Re-run with -Install to authorize a restorable temporary installation under '$toolsPath'." }
    if (Test-Path -LiteralPath $installedToolPath) {
        if (-not $preflight.InstallReplacementAuthorized) { throw 'Host preflight rejected the existing ACID installation as an unrecognized replacement target.' }
        foreach ($entry in @(Get-ChildItem -LiteralPath $installedToolPath -Force -Recurse)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Existing ACID installation contains a reparse point; refusing replacement.' }
        }
        if ((Get-Item -LiteralPath $installedToolPath -Force).PSIsContainer -ne $true) { throw 'Existing ACID installation is not a directory.' }
    }
    if (Test-Path -LiteralPath $sessionTargetPath) {
        $sessionPrecheck = Get-Item -LiteralPath $sessionTargetPath -Force
        if ($sessionPrecheck.PSIsContainer -or ($sessionPrecheck.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Existing session sidecar path is not a plain file; refusing replacement.' }
    }
    if ($installedFixturesPath -and (Test-Path -LiteralPath $installedFixturesPath)) {
        $fixturesPrecheck = Get-Item -LiteralPath $installedFixturesPath -Force
        if (-not $fixturesPrecheck.PSIsContainer -or ($fixturesPrecheck.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Existing ACID fixtures path is not a plain directory; refusing replacement.' }
    }
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    . ([scriptblock]::Create((Get-RenoiseDeploymentOperation)))

    if ($RenoiseProcessId -gt 0) {
        $selectedIdentity = if ($selectedIdentity) { $selectedIdentity } else { Get-RenoiseProcessIdentity -Id $RenoiseProcessId }
        Assert-RenoiseProcessIdentity -Identity $selectedIdentity
        $driverMayBeLoaded = $true
        Write-Information 'ACID development files are installed. In the selected Renoise window, reload the ACID tool if it is already loaded; do not restart that process.' -InformationAction Continue
        $processIdentity = $selectedIdentity
    }
    else {
        $launched = Start-RunnerOwnedProcess -SongPath ''
        $startedProcess = $launched.Process
        $startedIdentity = $launched.Identity
        $driverMayBeLoaded = $true
        $processIdentity = $startedIdentity
        $report.host.process_id = $startedIdentity.Id
        $report.host.process_start_time_utc = $startedIdentity.StartTimeUtc.ToString('o')
        Add-Trace -Operation 'process.start' -Status 'PASS' -Details @{ pid = $startedIdentity.Id; start_time_utc = $startedIdentity.StartTimeUtc.ToString('o') }
        $postLaunchPreflight = Get-Preflight -SelectedId $startedIdentity.Id
    }

    $processCheck = { Assert-RenoiseProcessIdentity -Identity $processIdentity }
    $bootstrap = Invoke-RenoiseDriverBootstrap -Session $session -Identity $processIdentity `
        -StartupTimeoutSeconds $StartupTimeoutSeconds -CommandTimeoutSeconds $CommandTimeoutSeconds `
        -ProcessCheck $processCheck
    $client = $bootstrap.Client
    Add-Trace -Operation 'driver.bootstrap' -Status 'PASS' -Details @{
        cold_process = $false; attempts = $bootstrap.Attempts; stages = @($bootstrap.AttemptDiagnostics)
    }
    try {
        $ping = $bootstrap.Ping
        $lastExpected = 'Authenticated ping uses protocol version 1 and the current run nonce'
        $lastActual = @{ protocol_version = $ping.protocol_version; nonce_matches = ($ping.session -ceq $session.Nonce) }
        if ($ping.protocol_version -ne 1 -or $ping.session -cne $session.Nonce) { throw [RenoiseRunnerAssertionException]::new('Authenticated handshake reported the wrong protocol or run nonce.') }
        Add-Trace -Operation 'driver.ping' -Status 'PASS' -Details @{ protocol_version = $ping.protocol_version; authenticated = $true }
        $capabilities = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'capabilities' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $requiredOperations = @('song.snapshot')
        if ($Suite -in @('Keyboard','All')) { $requiredOperations += @('gui.state','song.prepare_instrument_navigation') }
        if ($capabilities.protocol_version -ne 1 -or @($requiredOperations | Where-Object { $_ -notin @($capabilities.operations) }).Count -gt 0) { throw [RenoiseRunnerAssertionException]::new('Renoise driver capabilities are incomplete.') }
        $runtimeVersion = Get-VersionTriplet -Value ([string]$capabilities.renoise_version)
        $runtimeApiVersion = [string]$capabilities.api_version
        $manifestApiVersion = [string]$toolVersion.RenoiseScriptingTool.ApiVersion
        if ($runtimeApiVersion -cne $manifestApiVersion) { throw [RenoiseRunnerAssertionException]::new("Renoise API $runtimeApiVersion does not match ACID manifest API $manifestApiVersion.") }
        if ($runtimeVersion -ne $exeVersionTriplet) { throw [RenoiseRunnerAssertionException]::new("Connected Renoise runtime $runtimeVersion does not match selected executable $exeVersionTriplet.") }
        $report.host.renoise_runtime_version = [string]$capabilities.renoise_version
        $report.host.api_version = $runtimeApiVersion
        Add-Trace -Operation 'driver.capabilities' -Status 'PASS' -Details @{ operation_count = @($capabilities.operations).Count }

        $before = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'diagnostics' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $lastActual = $before
        $lastExpected = 'Ready document and no other pending commands before reset'
        if (-not $before.document_ready -or $before.pending_commands -ne 0 -or $before.queued_commands -ne 0 -or $before.document_transition_uncertain) {
            throw [RenoiseRunnerAssertionException]::new('Renoise host is not in a settled, ready document state; no document reset was attempted.')
        }
        Write-Information 'Creating a new empty Renoise document. If Renoise shows a dirty-song prompt, handle it yourself; the runner will not choose Save or Discard.' -InformationAction Continue
        $resetTimeoutMs = [Math]::Min(120000, $CommandTimeoutSeconds * 1000)
        $lastExpected = 'document.new completes only after release and new-document epoch barriers'
        $lastActual = @{ starting_epoch = $before.document_epoch; terminal_response = $false }
        $lastDiff = @{ terminal_response_received = $false; expected_epoch_greater_than = $before.document_epoch }
        $resetResponseTimeout = [Math]::Min(123, [Math]::Ceiling($resetTimeoutMs / 1000) + 3)
        Assert-RenoiseListenerOwner -Client $client -Identity $processIdentity
        $reset = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'document.new' -Arguments @{ timeout_ms = $resetTimeoutMs } -TimeoutSeconds $resetResponseTimeout -ProcessCheck $processCheck
        $lastActual = @{ starting_epoch = $before.document_epoch; observed_epoch = $reset.document_epoch; terminal_response = $true; operation = $reset.operation }
        $lastDiff = @{ terminal_response_received = $true; operation_matches = ($reset.operation -ceq 'document.new'); epoch_advanced = ($reset.document_epoch -gt $before.document_epoch) }
        if ($reset.operation -cne 'document.new' -or $reset.document_epoch -le $before.document_epoch) { throw [RenoiseRunnerAssertionException]::new('New-document command did not return an advanced observed document epoch.') }
        Add-Trace -Operation 'document.new' -Status 'PASS' -Details @{ previous_epoch = $before.document_epoch; observed_epoch = $reset.document_epoch }
        $snapshotBefore = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'song.snapshot' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $snapshotBeforeEpochMatches = $snapshotBefore.document_epoch -eq $reset.document_epoch
        $lastExpected = 'new document has self-consistent instrument/phrase inventory and no phrases'
        $lastActual = @{ instrument_count = $snapshotBefore.instrument_count; phrase_count = $snapshotBefore.phrase_count; document_epoch = $snapshotBefore.document_epoch }
        $reportedInstrumentCount = [int]$snapshotBefore.instrument_count
        $reportedPhraseCount = [int]$snapshotBefore.phrase_count
        $actualInstrumentCount = @($snapshotBefore.instruments).Count
        $actualPhraseCount = 0
        foreach ($instrument in @($snapshotBefore.instruments)) { $actualPhraseCount += @($instrument.phrases).Count }
        $selectionMatchesInventory = $snapshotBefore.selected_instrument_index -ge 1 -and $snapshotBefore.selected_instrument_index -le $actualInstrumentCount -and $snapshotBefore.selected_phrase_index -eq 0
        $inventoryDiff = @{
            snapshot_epoch_matches_reset = $snapshotBeforeEpochMatches
            instrument_count_matches_inventory = ($reportedInstrumentCount -eq $actualInstrumentCount)
            phrase_count_matches_inventory = ($reportedPhraseCount -eq $actualPhraseCount)
            unexpected_phrases = ($actualPhraseCount -ne 0)
            selection_matches_inventory = $selectionMatchesInventory
        }
        $lastDiff = $inventoryDiff
        if (-not $snapshotBeforeEpochMatches -or $reportedInstrumentCount -ne $actualInstrumentCount -or $reportedPhraseCount -ne $actualPhraseCount -or $actualPhraseCount -ne 0 -or -not $selectionMatchesInventory) {
            throw [RenoiseRunnerAssertionException]::new('New document snapshot epoch or inventory did not match the observed reset state.')
        }
        $snapshotBeforeJson = $snapshotBefore | ConvertTo-Json -Depth 20 -Compress
        $snapshotBeforeJson | Set-Content -LiteralPath (Join-Path $artifactRoot 'snapshot-before.json') -Encoding utf8NoBOM
        $snapshotBeforeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($snapshotBeforeJson))).ToLowerInvariant()
        $snapshotAfter = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'song.snapshot' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $snapshotAfterEpochMatches = $snapshotAfter.document_epoch -eq $reset.document_epoch
        $snapshotAfterJson = $snapshotAfter | ConvertTo-Json -Depth 20 -Compress
        $snapshotAfterJson | Set-Content -LiteralPath (Join-Path $artifactRoot 'snapshot-after.json') -Encoding utf8NoBOM
        $snapshotAfterHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($snapshotAfterJson))).ToLowerInvariant()
        $after = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'diagnostics' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $lastExpected = 'Read-only snapshots match and document epoch and queues remain settled'
        $lastActual = @{ before_sha256 = $snapshotBeforeHash; after_sha256 = $snapshotAfterHash; before_epoch = $before.document_epoch; after_epoch = $after.document_epoch; pending = $after.pending_commands; queued = $after.queued_commands; transition_uncertain = $after.document_transition_uncertain }
        $lastDiff = @{
            snapshot_changed = ($snapshotBeforeHash -cne $snapshotAfterHash)
            before_snapshot_epoch_matches_reset = $snapshotBeforeEpochMatches
            after_snapshot_epoch_matches_reset = $snapshotAfterEpochMatches
            epoch_changed = ($after.document_epoch -ne $reset.document_epoch)
            pending = $after.pending_commands
            queued = $after.queued_commands
            transition_uncertain = $after.document_transition_uncertain
            instrument_count_matches_inventory = $inventoryDiff.instrument_count_matches_inventory
            phrase_count_matches_inventory = $inventoryDiff.phrase_count_matches_inventory
            unexpected_phrases = $inventoryDiff.unexpected_phrases
            selection_matches_inventory = $inventoryDiff.selection_matches_inventory
        }
        $lastExpected = 'New document release/new epoch observed; consistent instrument inventory, zero phrases, stable snapshots, and zero pending commands'
        if (-not $snapshotBeforeEpochMatches -or -not $snapshotAfterEpochMatches -or $snapshotBeforeHash -cne $snapshotAfterHash -or $after.document_epoch -ne $reset.document_epoch -or
            $after.pending_commands -ne 0 -or $after.queued_commands -ne 0 -or $after.document_transition_uncertain) {
            throw [RenoiseRunnerAssertionException]::new('Reset document snapshot or diagnostics did not match the expected settled state.')
        }
        $report.document_epoch = $after.document_epoch
        Add-Trace -Operation 'song.snapshot' -Status 'PASS' -Details @{ sha256 = $snapshotAfterHash; document_epoch = $after.document_epoch }
        $scenarioResults = [Collections.Generic.List[object]]::new()
        if ($Suite -in @('Native','All')) {
            $scenarioResults.Add([pscustomobject]@{ name = 'transport'; suite = 'Native'; status = 'PASS'; expected = $lastExpected; actual = "protocol=$($ping.protocol_version); instruments=$($snapshotAfter.instrument_count); phrases=$($snapshotAfter.phrase_count); epoch=$($after.document_epoch)"; diff = $lastDiff })
        }
        $sendScenarioRequest = {
            param([string]$Operation, [hashtable]$Arguments)
            $timeoutSeconds = $CommandTimeoutSeconds
            if ($Operation -ceq 'document.new' -or $Operation -ceq 'document.load_fixture') {
                $timeoutMs = if ($Arguments.ContainsKey('timeout_ms')) { [int]$Arguments.timeout_ms } else { [Math]::Min(120000, $CommandTimeoutSeconds * 1000) }
                $timeoutSeconds = [Math]::Min(123, [Math]::Ceiling($timeoutMs / 1000) + 3)
            }
            Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation $Operation -Arguments $Arguments -TimeoutSeconds $timeoutSeconds -ProcessCheck $processCheck
        }
        $resetTimeoutSeconds = [Math]::Min(120, $CommandTimeoutSeconds)
        $scenarioExecutionPlan = [Collections.Generic.List[object]]::new()
        if ($VerifyScenarioOrder) {
            foreach ($catalogScenario in @($selectedCatalogScenarios)) {
                $scenarioExecutionPlan.Add([pscustomobject]@{ scenario = $catalogScenario; phase = 'individual' })
            }
            for ($index = $selectedCatalogScenarios.Count - 1; $index -ge 0; $index--) {
                $scenarioExecutionPlan.Add([pscustomobject]@{ scenario = $selectedCatalogScenarios[$index]; phase = 'reverse' })
            }
        }
        else {
            foreach ($catalogScenario in @($selectedCatalogScenarios)) {
                $scenarioExecutionPlan.Add([pscustomobject]@{ scenario = $catalogScenario; phase = 'catalog' })
            }
        }
        $scenarioOrderBaselines = @{}
        $scenarioOrderComparisons = [Collections.Generic.List[object]]::new()
        $scenarioOrderIdleSettlements = [Collections.Generic.List[object]]::new()
        $scenarioOrderPassed = $true
        foreach ($scenarioExecution in $scenarioExecutionPlan) {
            $catalogScenario = $scenarioExecution.scenario
            $scenarioPhase = $scenarioExecution.phase
            $artifactName = if ($VerifyScenarioOrder) { 'scenario-' + $scenarioPhase + '-' + $catalogScenario.name } else { 'scenario-' + $catalogScenario.name }
            $scenarioArtifactDirectory = Join-Path $artifactRoot $artifactName
            New-Item -ItemType Directory -Path $scenarioArtifactDirectory -Force | Out-Null
            $phaseLabel = if ($VerifyScenarioOrder) { " ($scenarioPhase)" } else { '' }
            $lastExpected = "scenario $($catalogScenario.name)$phaseLabel golden assertions hold; expects=$($catalogScenario.expects); $(@($catalogScenario.assertions).Count) assertions"
            $lastActual = $null
            $lastDiff = $null
            $result = Invoke-AcidNativeScenario -Scenario $catalogScenario -SendRequest $sendScenarioRequest -ArtifactDirectory $scenarioArtifactDirectory -ResetTimeoutSeconds $resetTimeoutSeconds -CommandTimeoutSeconds $CommandTimeoutSeconds
            $epochText = "$($result.observation.document_epoch_reset)->$($result.observation.document_epoch_loaded)"
            $shaText = (@($result.observation.snapshot_sha256) -join ',')
            $scenarioOrderComparison = $null
            $idleSettlementEvidence = $null
            if ($VerifyScenarioOrder -and $result.status -ceq 'PASS') {
                $postLoadDiagnostics = & $sendScenarioRequest 'diagnostics' @{}
                $settlement = $postLoadDiagnostics.native_inventory_settlement
                $settlementPassed = $null -ne $settlement -and
                    $settlement.idle_settlement_observed -is [bool] -and $settlement.idle_settlement_observed -and
                    ($settlement.matching_idle_cycles -is [int] -or $settlement.matching_idle_cycles -is [long]) -and
                    $settlement.matching_idle_cycles -ge 2 -and
                    $settlement.document_epoch -eq $result.observation.document_epoch_loaded
                $idleSettlementEvidence = [ordered]@{
                    observed = [bool]$settlementPassed
                    document_epoch = if ($settlement) { $settlement.document_epoch } else { $null }
                    matching_idle_cycles = if ($settlement) { $settlement.matching_idle_cycles } else { $null }
                    idle_settlement_observed = if ($settlement) { $settlement.idle_settlement_observed } else { $false }
                    instrument_count = if ($settlement) { $settlement.instrument_count } else { $null }
                    phrase_count = if ($settlement) { $settlement.phrase_count } else { $null }
                }
                $result.observation.post_load_idle_settlement = $idleSettlementEvidence
                $scenarioOrderIdleSettlements.Add([pscustomobject]@{
                    scenario = $catalogScenario.name
                    phase = $scenarioPhase
                    evidence = $idleSettlementEvidence
                })
                if (-not $settlementPassed) {
                    $scenarioOrderPassed = $false
                    $result.status = 'FAIL'
                    $result.observation.failure_reason = 'post-load idle settlement was not observed for the loaded document epoch'
                }

                $snapshot1Path = Join-Path $scenarioArtifactDirectory ($catalogScenario.name + '-snapshot-1.json')
                $snapshot2Path = Join-Path $scenarioArtifactDirectory ($catalogScenario.name + '-snapshot-2.json')
                if ((Test-Path -LiteralPath $snapshot1Path -PathType Leaf) -and (Test-Path -LiteralPath $snapshot2Path -PathType Leaf)) {
                    $snapshot1 = Read-ScenarioOrderSnapshot -Path $snapshot1Path
                    $snapshot2 = Read-ScenarioOrderSnapshot -Path $snapshot2Path
                    $normalizedSnapshot1Path = Join-Path $scenarioArtifactDirectory ($catalogScenario.name + '-snapshot-1-without-epoch.json')
                    $normalizedSnapshot2Path = Join-Path $scenarioArtifactDirectory ($catalogScenario.name + '-snapshot-2-without-epoch.json')
                    [IO.File]::WriteAllText($normalizedSnapshot1Path, $snapshot1.Canonical, [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText($normalizedSnapshot2Path, $snapshot2.Canonical, [Text.UTF8Encoding]::new($false))
                    if ($snapshot1.Canonical -cne $snapshot2.Canonical) {
                        $result.status = 'FAIL'
                        $result.observation.failure_reason = 'normalized snapshots differed within one scenario execution'
                        $scenarioOrderPassed = $false
                    }
                    if ($scenarioPhase -ceq 'individual') {
                        $scenarioOrderBaselines[[string]$catalogScenario.name] = [pscustomobject]@{
                            Snapshot1 = $snapshot1
                            Snapshot2 = $snapshot2
                        }
                    }
                    else {
                        $baseline = $scenarioOrderBaselines[[string]$catalogScenario.name]
                        $comparisonMatches = $false
                        if ($null -ne $baseline) {
                            $comparisonMatches = $baseline.Snapshot1.Canonical -ceq $snapshot1.Canonical -and
                                $baseline.Snapshot2.Canonical -ceq $snapshot2.Canonical
                        }
                        $scenarioOrderComparison = [ordered]@{
                            scenario = $catalogScenario.name
                            individual_epoch = if ($baseline) { $baseline.Snapshot1.DocumentEpoch } else { $null }
                            reverse_epoch = $snapshot1.DocumentEpoch
                            individual_snapshot_1_sha256 = if ($baseline) { $baseline.Snapshot1.Sha256 } else { $null }
                            reverse_snapshot_1_sha256 = $snapshot1.Sha256
                            individual_snapshot_2_sha256 = if ($baseline) { $baseline.Snapshot2.Sha256 } else { $null }
                            reverse_snapshot_2_sha256 = $snapshot2.Sha256
                            excluded_snapshot_fields = @('document_epoch')
                            matches = $comparisonMatches
                        }
                        $scenarioOrderComparisons.Add($scenarioOrderComparison)
                        if (-not $scenarioOrderComparison.matches) {
                            $result.status = 'FAIL'
                            $result.observation.failure_reason = 'canonical snapshots differed between individual and reverse catalog execution'
                            $scenarioOrderPassed = $false
                        }
                    }
                }
                else {
                    $result.status = 'FAIL'
                    $result.observation.failure_reason = 'scenario snapshots were not written for order comparison'
                    $scenarioOrderPassed = $false
                }
                if ($result.status -ne 'PASS') { $scenarioOrderPassed = $false }
            }
            $lastActual = @{
                status = $result.status
                phase = $scenarioPhase
                epochs = $epochText
                snapshot_sha256 = @($result.observation.snapshot_sha256)
                post_load_idle_settlement = $idleSettlementEvidence
                order_comparison = $scenarioOrderComparison
                failure_reason = $result.observation.failure_reason
            }
            $scenarioDiff = Get-AcidScenarioReportDiff -Result $result
            $lastDiff = $scenarioDiff
            $actualSummary = "epochs=$epochText; snapshot_sha256=$shaText"
            if ($VerifyScenarioOrder) {
                if ($result.status -cne 'PASS') { $scenarioOrderPassed = $false }
                $orderMatchText = if ($null -ne $scenarioOrderComparison) { [string]$scenarioOrderComparison.matches } else { 'baseline' }
                $actualSummary += "; phase=$scenarioPhase; idle_cycles=$(if ($idleSettlementEvidence) { $idleSettlementEvidence.matching_idle_cycles } else { 'unavailable' }); order_match=$orderMatchText"
            }
            if ($result.status -ne 'PASS' -and $result.observation.failure_reason) { $actualSummary += "; reason=$($result.observation.failure_reason)" }
            $scenarioExpected = "scenario $($catalogScenario.name) golden assertions hold; expects=$($result.expects); $(@($catalogScenario.assertions).Count) assertions"
            $scenarioResult = [ordered]@{
                name = $catalogScenario.name
                suite = 'Native'
                status = $result.status
                expected = $scenarioExpected
                actual = $actualSummary
                diff = $scenarioDiff
            }
            if ($VerifyScenarioOrder) { $scenarioResult.order_phase = $scenarioPhase }
            $scenarioResults.Add([pscustomobject]$scenarioResult)
            $traceName = if ($VerifyScenarioOrder) { "scenario.$scenarioPhase.$($catalogScenario.name)" } else { "scenario.$($catalogScenario.name)" }
            $traceDetails = @{
                epochs = $epochText
                snapshot_sha256 = @($result.observation.snapshot_sha256)
                failure_reason = $result.observation.failure_reason
            }
            if ($VerifyScenarioOrder) {
                $traceDetails.phase = $scenarioPhase
                $traceDetails.post_load_idle_settlement = $idleSettlementEvidence
                $traceDetails.order_comparison = $scenarioOrderComparison
            }
            Add-Trace -Operation $traceName -Status $result.status -Details $traceDetails
        }
        if ($VerifyScenarioOrder) {
            $expectedComparisonCount = $selectedCatalogScenarios.Count
            $expectedIdleSettlementCount = $selectedCatalogScenarios.Count * 2
            $report.scenario_order_acceptance.status = if ($scenarioOrderPassed -and
                $scenarioOrderComparisons.Count -eq $expectedComparisonCount -and
                $scenarioOrderIdleSettlements.Count -eq $expectedIdleSettlementCount) { 'PASS' } else { 'FAIL' }
            $report.scenario_order_acceptance.comparisons = @($scenarioOrderComparisons)
            $report.scenario_order_acceptance.idle_settlements = @($scenarioOrderIdleSettlements)
        }
        $lastExpected = 'Scenario run leaves a settled new document with drained queues'
        $lastActual = @{ terminal_response = $false }
        $lastDiff = $null
        $cleanupReset = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'document.new' -Arguments @{ timeout_ms = $resetTimeoutMs } -TimeoutSeconds $resetResponseTimeout -ProcessCheck $processCheck
        if ($cleanupReset.operation -cne 'document.new') { throw 'Scenario cleanup reset did not complete a new document.' }
        $cleanupDiagnostics = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'diagnostics' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $lastActual = @{ document_epoch = $cleanupDiagnostics.document_epoch; pending = $cleanupDiagnostics.pending_commands; queued = $cleanupDiagnostics.queued_commands; transition_uncertain = $cleanupDiagnostics.document_transition_uncertain; terminal_response = $true }
        $lastDiff = @{
            terminal_response_received = $true
            document_ready = $cleanupDiagnostics.document_ready
            pending = $cleanupDiagnostics.pending_commands
            queued = $cleanupDiagnostics.queued_commands
            transition_uncertain = $cleanupDiagnostics.document_transition_uncertain
        }
        if (-not $cleanupDiagnostics.document_ready -or $cleanupDiagnostics.pending_commands -ne 0 -or
            $cleanupDiagnostics.queued_commands -ne 0 -or $cleanupDiagnostics.document_transition_uncertain) {
            throw 'Scenario cleanup did not leave a settled, ready document.'
        }
        $report.document_epoch = $cleanupDiagnostics.document_epoch
        Add-Trace -Operation 'scenario.cleanup' -Status 'PASS' -Details @{ document_epoch = $cleanupDiagnostics.document_epoch }
        if ($AcceptanceCase) {
            $lastExpected = "Fixed native acceptance case '$AcceptanceCase' completes with independent postconditions"
            $lastActual = $null
            $lastDiff = $null
            if ($AcceptanceCase -ceq 'ownership-negatives') {
                $donor = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
                    -Arguments @{ case = 'import-donor' } -TimeoutSeconds 180 -ProcessCheck $processCheck
                if ($donor.status -cne 'PASS') { throw 'Native donor export failed.' }
                $installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
                Add-Trace -Operation 'acceptance.import-donor' -Status 'PASS' -Details $donor
                $null = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'document.new' `
                    -Arguments @{ timeout_ms = $resetTimeoutMs } -TimeoutSeconds $resetResponseTimeout -ProcessCheck $processCheck
            }
            if ($revisionUndoAcceptance -or $metadataUndoAcceptance -or $metadataRecoveryAcceptance) {
                $undoFixtureCase = if ($revisionLiveUndoAcceptance) { 'revision-live-undo-fixture' } elseif ($revisionUndoAcceptance -or $metadataUndoAcceptance -or $metadataRecoveryAcceptance) { 'revision-undo-fixture' }
                $undoPrepareCase = if ($metadataRecoveryAcceptance) { 'metadata-recovery-prepare' } elseif ($metadataUndoAcceptance) { 'metadata-undo-prepare' } elseif ($revisionLiveUndoAcceptance) { 'revision-live-undo-prepare' } elseif ($revisionUndoAcceptance) { 'revision-undo-prepare' }
                $undoFixtureName = 'acceptance-revision-undo.xrns'
                $undoFixture = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
                    -Arguments @{ case = $undoFixtureCase } -TimeoutSeconds 180 -ProcessCheck $processCheck
                if ($undoFixture.status -cne 'PASS') { throw "Native undo fixture could not be saved: $(ConvertTo-AcidCanonicalJson $undoFixture)" }
                $installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
                $null = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'document.load_fixture' `
                    -Arguments @{ root = 'fixtures'; name = $undoFixtureName; timeout_ms = 120000 } `
                    -TimeoutSeconds 123 -ProcessCheck $processCheck
                $prepare = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
                    -Arguments @{ case = $undoPrepareCase } `
                    -TimeoutSeconds ([Math]::Max($CommandTimeoutSeconds, 180)) -ProcessCheck $processCheck
                if ($prepare.case -cne $undoPrepareCase -or $prepare.status -cne 'PASS' -or $prepare.action_ready -ne $true) {
                    throw [RenoiseRunnerAssertionException]::new("Native undo callback dialog was not ready for the guarded Enter action: $(ConvertTo-AcidCanonicalJson $prepare)")
                }
                Add-Trace -Operation "acceptance.$undoPrepareCase" -Status 'PASS' -Details $prepare
                $focusGuard = Invoke-AcidKeyboardHelper -Executable $keyboardExecutable -HelperScript $keyboardHelperPath `
                    -Mode SelfTestFocusMismatch -ProcessId $processIdentity.Id -ProcessCheck $processCheck
                if ($focusGuard.ExitCode -ne 0 -or $focusGuard.StdOut -notmatch '^PASS self-test focus-mismatch:') {
                    throw "AutoHotkey focus-mismatch guard failed before native undo action: $($focusGuard.StdErr) $($focusGuard.StdOut)"
                }
                Add-Trace -Operation "acceptance.$AcceptanceCase.focus_guard" -Status 'PASS' -Details @{ input_sent = $false; output = $focusGuard.StdOut }
                $enterResult = Invoke-AcidKeyboardHelper -Executable $keyboardExecutable -HelperScript $keyboardHelperPath `
                    -Mode Send -ProcessId $processIdentity.Id -Keys '{Enter}' -ProcessCheck $processCheck `
                    -AllowFocusActivation:$AllowKeyboardFocusActivation -TimeoutSeconds $keyboardConfiguration.TimeoutSeconds
                if ($enterResult.ExitCode -ne 0) {
                    $enterError = if ($enterResult.StdErr) { $enterResult.StdErr } else { $enterResult.StdOut }
                    throw "Guarded Enter action for native undo acceptance failed: $enterError"
                }
                Add-Trace -Operation "acceptance.$AcceptanceCase.enter" -Status 'PASS' -Details @{ pid = $processIdentity.Id; keys = '{Enter}'; output = $enterResult.StdOut }
            }
            $acceptanceArguments = @{ case = $AcceptanceCase }
            if ($ProductionCheckpoint) {
                $checkpointRoot = [IO.Path]::GetFullPath($ProductionCheckpoint)
                Assert-DirectoryHasNoReparsePoints -Path $checkpointRoot
                foreach ($name in @('acceptance-production.xrns','acceptance-production-baseline.json')) {
                    Copy-Item -LiteralPath (Join-Path $checkpointRoot $name) -Destination (Join-Path $installedFixturesPath $name)
                }
                $installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
                $null = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'document.load_fixture' `
                    -Arguments @{root='fixtures';name='acceptance-production.xrns';timeout_ms=120000} `
                    -TimeoutSeconds 123 -ProcessCheck $processCheck
                $acceptanceArguments.stage='cold-verify'
            }
            if ($productionLatency) { $acceptanceArguments.midi_output_device = $MidiOutputDevice }
            if ($profileApplies) { $acceptanceArguments.profile = $profileResolution.Profile }
            $acceptanceTimeout = if ($AcceptanceCase -cin @('production-session-8x8','production-stress-16x8')) { 3600 } else { [Math]::Max($CommandTimeoutSeconds, 180) }
            $acceptance = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' -Arguments $acceptanceArguments -TimeoutSeconds $acceptanceTimeout -ProcessCheck $processCheck
            if ($productionSessionAcceptance -and -not $ProductionCheckpoint) {
                for ($action = 0; $action -lt 2 -and $acceptance.status -ceq 'PASS'; $action++) {
                    if ($acceptance.action_ready -ne $true) { throw 'Production GUI user action was not prepared.' }
                    $enterResult = Invoke-AcidKeyboardHelper -Executable $keyboardExecutable -HelperScript $keyboardHelperPath `
                        -Mode Send -ProcessId $processIdentity.Id -Keys '{Enter}' -ProcessCheck $processCheck `
                        -AllowFocusActivation:$AllowKeyboardFocusActivation -TimeoutSeconds $keyboardConfiguration.TimeoutSeconds
                    if ($enterResult.ExitCode -ne 0) { throw "Production Enter callback failed: $($enterResult.StdErr)" }
                    $acceptance = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' `
                        -Arguments @{case=$AcceptanceCase;stage='undo';midi_output_device=$MidiOutputDevice} `
                        -TimeoutSeconds 3600 -ProcessCheck $processCheck
                }
            }
            if ($productionSessionAcceptance -and $acceptance.status -ceq 'PASS') {
              if (-not $ProductionCheckpoint) {
                if ($acceptance.action_ready -ne $false -or $acceptance.phases.native_undo -cne 'PASS') {
                    throw 'Production native Undo/Redo evidence is incomplete.'
                }
                $installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
                $productionSongPath = Join-Path $installedFixturesPath 'acceptance-production.xrns'
                foreach ($coldStage in @('cold-regenerate','cold-verify')) {
                    $songHash = (Get-FileHash -LiteralPath $productionSongPath -Algorithm SHA256).Hash
                    Copy-Item -LiteralPath $productionSongPath -Destination (Join-Path $artifactRoot "$coldStage.xrns")
                    Add-Trace -Operation 'production.xrns' -Status 'PASS' -Details @{stage=$coldStage;sha256=$songHash}
                    $cold = Invoke-ColdProcessAcceptance -SongPath $productionSongPath -Case $AcceptanceCase `
                        -Stage $coldStage -MidiOutputDevice $MidiOutputDevice -ExpectedBaseline $acceptance.saved_baseline
                    if ($coldStage -ceq 'cold-regenerate') {
                        $acceptance.saved_baseline = $cold.saved_baseline
                        $installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
                    }
                }
                $acceptance.phases.cold_reopen='PASS'
              }
              else {
                $acceptance | Add-Member -NotePropertyName execution_mode -NotePropertyValue 'PLAYBACK_CHECKPOINT'
              }
                $acceptance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $artifactRoot 'production-functional.json') -Encoding utf8
                $midiEvidence = Invoke-ProductionMidiCapture
                $acceptance.midi_counts = $midiEvidence.midi_counts
                $acceptance.midi_events = $midiEvidence.midi_events
                $acceptance | Add-Member -NotePropertyName midi_receiver_proofs -NotePropertyValue $midiEvidence.receiver_proofs -Force
                $acceptance.status='FAIL'
                if ($acceptance.midi_counts.note -le 0 -or $acceptance.midi_counts.off -le 0 -or $acceptance.midi_counts.bend -le 0) {
                    $acceptance | Add-Member -NotePropertyName midi_status -NotePropertyValue 'FAIL' -Force
                    $acceptance | Add-Member -NotePropertyName audio_status -NotePropertyValue 'NOT_RUN' -Force
                    $acceptance.phases.playback='FAIL'
                    $acceptance | Add-Member -NotePropertyName reason -NotePropertyValue 'multitrack MIDI note/OFF/pitch-bend events were not captured' -Force
                }
                else {
                    $acceptance | Add-Member -NotePropertyName midi_status -NotePropertyValue 'PASS' -Force
                    if ($AudioInputDevice) {
                        $audioEvidence = Invoke-ProductionAudioCapture
                        $acceptance | Add-Member -NotePropertyName audio_evidence -NotePropertyValue $audioEvidence -Force
                        $acceptance | Add-Member -NotePropertyName audio_status -NotePropertyValue 'PASS' -Force
                        $acceptance.phases.playback='PASS'
                        $acceptance.status='PASS'
                        $acceptance.complete=-not [bool]$ProductionCheckpoint
                    }
                    else {
                        $acceptance | Add-Member -NotePropertyName audio_status -NotePropertyValue 'WAIVED' -Force
                        $acceptance.phases.playback='PASS'
                        $acceptance.status='PASS'
                        $acceptance.complete=-not [bool]$ProductionCheckpoint
                        $acceptance | Add-Member -NotePropertyName playback_evidence -NotePropertyValue 'MIDI_CAPTURED_AUDIO_NOT_REQUIRED' -Force
                    }
                }
            }
            if ($productionSessionAcceptance -and $acceptance.midi_status -and $acceptance.audio_status) {
                $productionPlaybackSummary = 'MIDI {0}; audio {1}' -f $acceptance.midi_status, $acceptance.audio_status
            }
            $acceptanceStatus = [string]$acceptance.status
            if ($acceptanceStatus -cnotin @('PASS','FAIL','ERROR') -or $acceptance.case -cne $AcceptanceCase) {
                throw 'Native acceptance response did not match the selected case.'
            }
            if ($profileApplies -and $acceptance.instrumentation_profile -cne $profileResolution.Profile) {
                throw 'Native acceptance response did not use the selected instrumentation profile.'
            }
            $acceptanceActual = ConvertTo-AcidCanonicalJson $acceptance
            $lastActual = $acceptance
            $lastDiff = if ($acceptanceStatus -ceq 'PASS') { $null } else { $acceptance }
            $scenarioResults.Add([pscustomobject]@{
                name = "acceptance.$AcceptanceCase"
                suite = 'Native'
                status = $acceptanceStatus
                expected = $lastExpected
                actual = $acceptanceActual
                diff = $lastDiff
            })
            Add-Trace -Operation "acceptance.$AcceptanceCase" -Status $acceptanceStatus -Details $acceptance
            if ($metadataRecoveryAcceptance -and $acceptanceStatus -ceq 'PASS') {
                $recoveryFixtureName = 'acceptance-metadata-recovery.xrns'
                if ($acceptance.roundtrip_fixture -cne $recoveryFixtureName) {
                    throw 'Recovery acceptance returned an unexpected fixture filename.'
                }
                $recoverySongPath = Join-Path $installedFixturesPath $recoveryFixtureName
                $recoverySong = Get-Item -LiteralPath $recoverySongPath -Force -ErrorAction Stop
                if ($recoverySong.PSIsContainer -or ($recoverySong.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $recoverySong.Length -le 0) {
                    throw 'Recovery acceptance did not save a plain, nonempty XRNS fixture.'
                }
                $installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
                Copy-Item -LiteralPath $recoverySongPath -Destination (Join-Path $artifactRoot $recoveryFixtureName)
                $coldRecoveryCase = 'metadata-recovery-cold'
                $null = Invoke-ColdProcessAcceptance -SongPath $recoverySongPath -Case $coldRecoveryCase -ExpectedBaseline $acceptance.saved_baseline
                if ((Get-DirectoryHash -Path $installedFixturesPath) -cne $installedFixturesHash) {
                    throw 'Cold recovery verification changed saved fixture files.'
                }
            }
            if ($AcceptanceCase -ceq 'ownership-negatives' -and
                ($acceptance.native_cross_song_import_blocked -ne $true -or
                 $donor.donor_phrase -cne $acceptance.imported_donor_phrase)) {
                throw [RenoiseRunnerAssertionException]::new('Native imported phrase differs from the independent donor snapshot or was not blocked.')
            }
        }
        $report.scenarios = @($scenarioResults)
        if ($Suite -in @('Keyboard','All')) {
            $activeSuite = 'Keyboard'
            $focusGuard = Invoke-AcidKeyboardHelper -Executable $keyboardExecutable -HelperScript $keyboardHelperPath -Mode SelfTestFocusMismatch -ProcessId $processIdentity.Id -ProcessCheck $processCheck
            if ($focusGuard.ExitCode -ne 0 -or $focusGuard.StdOut -notmatch '^PASS self-test focus-mismatch:') {
                throw "AutoHotkey focus-mismatch guard failed: $($focusGuard.StdErr) $($focusGuard.StdOut)"
            }
            $report.keyboard.negative_cases = @($report.keyboard.negative_cases) + @([pscustomobject]@{ name = 'stolen_focus'; status = 'PASS'; input_sent = $false; simulated = $true })
            Add-Trace -Operation 'keyboard.negative.stolen_focus' -Status 'PASS' -Details @{ simulated = $true; input_sent = $false; output = $focusGuard.StdOut }
            $journey = Invoke-AcidKeyboardJourney -Client $client -Session $session -Configuration $keyboardConfiguration -Executable $keyboardExecutable -HelperScript $keyboardHelperPath -ProcessId $processIdentity.Id -ProcessCheck $processCheck -AllowFocusActivation:$AllowKeyboardFocusActivation -CommandTimeoutSeconds $CommandTimeoutSeconds
            $report.keyboard.journey = $journey
            $report.keyboard.status = 'PASS'
            $report.keyboard.negative_cases = @($report.keyboard.negative_cases) + @([pscustomobject]@{ name = 'gui_timeout'; status = 'PASS'; input_sent = $false })
            Add-Trace -Operation 'keyboard.journey' -Status 'PASS' -Details $journey
            Add-Trace -Operation 'keyboard.negative.gui_timeout' -Status 'PASS' -Details @{ input_sent = $false; timeout_seconds = $keyboardConfiguration.TimeoutSeconds }
            $scenarioResults.Add([pscustomobject]@{ name = 'keyboard'; suite = 'Keyboard'; status = 'PASS'; expected = 'Configured ACID shortcut opens the dialog; native instrument navigation changes the selected index in song readback'; actual = "shortcut=$($journey.shortcut); navigation=$($journey.navigation); selected=$($journey.selected_instrument_before)->$($journey.selected_instrument_after)"; diff = $null })
        }
        $report.scenarios = @($scenarioResults)
        $failedScenarios = @($scenarioResults | Where-Object { $_.status -cne 'PASS' })
        $scenarioErrors = @($scenarioResults | Where-Object { $_.status -cnotin @('PASS', 'FAIL', 'SKIP', 'MANUAL') })
        $scenarioSkips = @($scenarioResults | Where-Object { $_.status -cin @('SKIP', 'MANUAL') })
        $orderAcceptanceFailed = $false
        if ($VerifyScenarioOrder) { $orderAcceptanceFailed = $report.scenario_order_acceptance.status -cne 'PASS' }
        if ($failedScenarios.Count -eq 0 -and -not $orderAcceptanceFailed) { $report.status = 'PASS' }
        else {
            $assertionFailures = @($scenarioResults | Where-Object { $_.status -eq 'FAIL' })
            $report.status = if ($scenarioErrors.Count -gt 0) { 'ERROR' }
                elseif ($scenarioSkips.Count -gt 0 -and $assertionFailures.Count -eq 0) { 'SKIP' }
                else { 'FAIL' }
            $failureDetails = @($failedScenarios | ForEach-Object { "$($_.name): $($_.actual)" })
            if ($orderAcceptanceFailed) { $failureDetails += "scenario-order acceptance: $($report.scenario_order_acceptance.status)" }
            $report.error = "Scenario $($report.status.ToLowerInvariant()): " + ($failureDetails -join '; ')
        }
        $safeToRestore = Stop-RenoiseDriver -Client $client -Session $session -SessionPath $sessionTargetPath -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        Add-Trace -Operation 'driver.shutdown' -Status 'PASS' -Details @{ renoise_left_open = [bool]$selectedIdentity }
    }
    finally {
        if ($client -and -not $safeToRestore) {
            try {
                Assert-RenoiseListenerOwner -Client $client -Identity $processIdentity
                $safeToRestore = Stop-RenoiseDriver -Client $client -Session $session -SessionPath $sessionTargetPath -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
                Add-Trace -Operation 'driver.shutdown' -Status 'PASS' -Details @{ after_error = $true }
            }
            catch { Add-Trace -Operation 'driver.shutdown' -Status 'ERROR' -Details @{ message = $_.Exception.Message } }
        }
        if ($client) { $client.Dispose() }
    }

    if ($startedIdentity) {
        $finalProcessForceStopped = Stop-RunnerOwnedProcess -Process $startedProcess -Identity $startedIdentity -Context 'cleanup'
        $startedProcessForceStopped = $startedProcessForceStopped -or $finalProcessForceStopped
        $safeToRestore = $true
        $startedProcessClosed = $true
        Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ launched_process_closed_cleanly = (-not $finalProcessForceStopped); force_stopped = $finalProcessForceStopped }
    }

}
catch {
    $failureMessage = $_.Exception.Message
    $failureStatus = if ($_.Exception -is [RenoiseRunnerAssertionException]) { 'FAIL' } else { 'ERROR' }
    $report.status = $failureStatus
    $report.error = $failureMessage
    if ($VerifyScenarioOrder -and $report.scenario_order_acceptance -is [Collections.IDictionary]) {
        $report.scenario_order_acceptance['status'] = $failureStatus
        $report.scenario_order_acceptance['error'] = $failureMessage
    }
    if ($report.keyboard -and $report.keyboard.status -eq 'RUNNING') { $report.keyboard.status = 'ERROR' }
    $failureScenario = [pscustomobject]@{
        name = if ($Scenario) { $Scenario } else { 'all' }
        suite = $activeSuite
        status = $failureStatus
        expected = $lastExpected
        actual = if ($null -ne $lastActual) { $lastActual } else { $failureMessage }
        diff = if ($null -ne $lastDiff) { $lastDiff } else { @{ error = $failureMessage } }
    }
    if (@($report.scenarios).Count -eq 0) { $report.scenarios = @($failureScenario) }
    else { $report.scenarios = @($report.scenarios) + @([pscustomobject]@{
        name = 'runner-cleanup'
        suite = $activeSuite
        status = 'ERROR'
        expected = 'Session, process, and temporary installation cleanup completes safely'
        actual = $failureMessage
        diff = @{ cleanup_error = $failureMessage }
    }) }
    Add-Trace -Operation 'runner' -Status $failureStatus -Details @{ message = $failureMessage }
}
finally {
    if ($deploymentStarted -and (-not $driverMayBeLoaded -or ($startedProcess -and -not $startedIdentity))) {
        if (-not $startedProcess) { $safeToRestore = $true }
        else {
            try {
                $startedProcess.Refresh()
                if ($startedProcess.HasExited) {
                    $safeToRestore = $true
                    Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ launched_process_exited_before_identity_validation = $true }
                }
                else {
                    Add-Trace -Operation 'install.restore_deferred' -Status 'ERROR' -Details @{ reason = 'Runner-launched process is active but its identity could not be validated.'; backup_retained = $true }
                }
            }
            catch {
                Add-Trace -Operation 'install.restore_deferred' -Status 'ERROR' -Details @{ reason = $_.Exception.Message; backup_retained = $true }
            }
        }
    }
    if ($startedIdentity -and -not $startedProcessClosed) {
        try {
            $errorForceStopped = Stop-RunnerOwnedProcess -Process $startedProcess -Identity $startedIdentity -Context 'after-error'
            $startedProcessForceStopped = $startedProcessForceStopped -or $errorForceStopped
            $safeToRestore = $true
            $startedProcessClosed = $true
            Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{
                after_error = $true
                launched_process_closed_cleanly = (-not $errorForceStopped)
                force_stopped = $errorForceStopped
            }
        }
        catch { Add-Trace -Operation 'process.shutdown' -Status 'ERROR' -Details @{ message = $_.Exception.Message } }
    }
    if ($deploymentStarted -and $safeToRestore) {
      try {
        Save-ProductionFixtureArtifacts
        . ([scriptblock]::Create((Get-RenoiseRestorationOperation)))
    }
      catch {
        $report.status = 'ERROR'
        $report.error = (@($report.error, "ACID installation restoration failed: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
        $report.scenarios = @($report.scenarios) + @([pscustomobject]@{
            name = 'runner-cleanup'
            suite = $Suite
            status = 'ERROR'
            expected = 'Temporary installation is removed and the prior installation restored without overwriting changed files'
            actual = $_.Exception.Message
            diff = @{ restoration_failed = $true }
        })
        Add-Trace -Operation 'install.restore' -Status 'ERROR' -Details @{
            message = $_.Exception.Message
            artifact_backup = if ($backupToolPath -and (Test-Path -LiteralPath $backupToolPath)) { $backupToolPath } else { $null }
            same_volume_restore_path = if ($localBackupToolPath -and (Test-Path -LiteralPath $localBackupToolPath)) { $localBackupToolPath } else { $null }
            session_backup = if ($sessionBackupPath -and (Test-Path -LiteralPath $sessionBackupPath)) { $sessionBackupPath } else { $null }
            same_volume_session_restore_path = if ($localBackupSessionPath -and (Test-Path -LiteralPath $localBackupSessionPath)) { $localBackupSessionPath } else { $null }
            fixtures_backup = if ($fixturesBackupPath -and (Test-Path -LiteralPath $fixturesBackupPath)) { $fixturesBackupPath } else { $null }
            same_volume_fixtures_restore_path = if ($localBackupFixturesPath -and (Test-Path -LiteralPath $localBackupFixturesPath)) { $localBackupFixturesPath } else { $null }
        }
      }
    }
    elseif ($deploymentStarted) {
        $report.status = 'ERROR'
        $retainedMessage = 'Temporary install was retained because the development driver/process did not reach a verified clean shutdown.'
        if ($report.error) { $report.error = "$($report.error) $retainedMessage" } else { $report.error = $retainedMessage }
        $report.scenarios = @($report.scenarios) + @([pscustomobject]@{
            name = 'runner-cleanup'
            suite = $Suite
            status = 'ERROR'
            reason = 'Host or process shutdown was not verified; restoration was withheld to avoid replacing a live or changed installation.'
            expected = 'Temporary installation is restored only after verified shutdown'
            actual = @{ install_retained = $true; process_id = $report.host.process_id }
            diff = @{ restoration_withheld = $true }
        })
        Add-Trace -Operation 'install.restore' -Status 'ERROR' -Details @{
            reason = 'shutdown not verified'
            install_target = $installedToolPath
            artifact_backup = $backupToolPath
            same_volume_restore_path = $localBackupToolPath
            session_backup = $sessionBackupPath
            same_volume_session_restore_path = $localBackupSessionPath
        }
    }
    $clock.Stop()
    $report.elapsed_ms = $clock.ElapsedMilliseconds
    if (Test-Path -LiteralPath $artifactRoot -PathType Container) {
        $reportPath = Join-Path $artifactRoot 'report.json'
        $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
        Write-Output "Run report: $reportPath"
    }
}

if ($productionPlaybackSummary) {
    Write-Output "Production playback summary: $productionPlaybackSummary"
}
if ($report.status -eq 'PASS') {
    Write-Output 'PASS interactive Renoise runner'
    exit 0
}
Write-Error "Interactive Renoise runner $($report.status): $($report.error)"
exit 1
