#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('ACID')][string]$Tool = 'ACID',
    [ValidateSet('Native','Keyboard','All')][string]$Suite = 'Native',
    [string]$Scenario,
    [string]$AcceptanceCase,
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
    document_epoch = $null
    elapsed_ms = 0
    operation_trace = @()
    scenarios = @()
    keyboard = $null
    scenario_order_acceptance = $null
    error = $null
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$transportOnly = $Suite -eq 'Keyboard' -or $Scenario -ceq 'transport'

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
    if ($AcceptanceCase -and $AcceptanceCase -cnotin @('make-independent','draft-recovery','reopen-independent','api-probe','integrity-observers','editor-responsiveness')) {
        throw "Unsupported native acceptance case '$AcceptanceCase'."
    }
    if ($AcceptanceCase -and $Suite -ne 'Native') { throw '-AcceptanceCase requires -Suite Native.' }
    if ($AllowKeyboardFocusActivation -and $Suite -eq 'Native') {
        throw '-AllowKeyboardFocusActivation is only valid for Keyboard or All suites.'
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

    Import-Module (Join-Path $repoRoot 'tests/renoise/runner.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests/renoise/host_preflight.psm1') -Force
    $scenarioDirectory = Join-Path $repoRoot 'tests/renoise/acid/scenarios'
    $selectedCatalogScenarios = if ($Suite -in @('Native','All')) {
        @(Get-AcidInteractiveScenarioSelection -Scenario $Scenario -Directory $scenarioDirectory)
    } else { @() }
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
        $startedProcess = Start-Process -FilePath $script:resolvedExe -WindowStyle Normal -PassThru
        $startedAt = $startedProcess.StartTime.ToUniversalTime()
        $capturedStartedIdentity = Get-RenoiseProcessIdentity -Id $startedProcess.Id -WaitMilliseconds 5000
        if (-not [string]::Equals($capturedStartedIdentity.Path, $script:resolvedExe, [StringComparison]::OrdinalIgnoreCase)) { throw 'Started Renoise process does not match the verified executable.' }
        if ($capturedStartedIdentity.StartTimeUtc -ne $startedAt) { throw 'Started Renoise process changed identity before metadata became available.' }
        $startedIdentity = $capturedStartedIdentity
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
            $acceptance = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' -Arguments @{ case = $AcceptanceCase } -TimeoutSeconds ([Math]::Max($CommandTimeoutSeconds, 180)) -ProcessCheck $processCheck
            $acceptanceStatus = [string]$acceptance.status
            if ($acceptanceStatus -cnotin @('PASS','FAIL','ERROR') -or $acceptance.case -cne $AcceptanceCase) {
                throw 'Native acceptance response did not match the selected case.'
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
            if ($AcceptanceCase -ceq 'make-independent' -and $acceptanceStatus -ceq 'PASS') {
                if ($acceptance.roundtrip_fixture -cne 'acceptance-independent.xrns') {
                    throw 'Make Independent did not return the fixed round-trip fixture name.'
                }
                $roundTripPath = Join-Path $installedFixturesPath 'acceptance-independent.xrns'
                $roundTripItem = Get-Item -LiteralPath $roundTripPath -Force -ErrorAction Stop
                if ($roundTripItem.PSIsContainer -or ($roundTripItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Make Independent round-trip output is not a plain fixture file.'
                }
                $sourceFixtureNames = @(Get-ChildItem -LiteralPath $fixturesSourcePath -File | ForEach-Object { $_.Name })
                $expectedFixtureNames = @(@($sourceFixtureNames + @('acceptance-independent.xrns')) | Sort-Object -Unique)
                $installedFixtureNames = @(Get-ChildItem -LiteralPath $installedFixturesPath -File | ForEach-Object Name | Sort-Object -Unique)
                if (($installedFixtureNames -join '|') -cne ($expectedFixtureNames -join '|')) {
                    throw 'Make Independent changed unexpected files in the temporary fixture directory.'
                }
                $installedFixturesHash = Get-DirectoryHash -Path $installedFixturesPath
                $roundTrip = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'document.load_fixture' -Arguments @{ root = 'fixtures'; name = 'acceptance-independent.xrns'; timeout_ms = 120000 } -TimeoutSeconds ([Math]::Min(123, [Math]::Ceiling(120000 / 1000) + 3)) -ProcessCheck $processCheck
                if ($roundTrip.operation -cne 'document.load_fixture' -or $roundTrip.document_epoch -le $report.document_epoch) {
                    throw 'Saved Make Independent song did not reload into a new document epoch.'
                }
                $report.document_epoch = $roundTrip.document_epoch
                Add-Trace -Operation 'acceptance.roundtrip_reload' -Status 'PASS' -Details @{ fixture = $acceptance.roundtrip_fixture; document_epoch = $roundTrip.document_epoch }
                $reloadedSnapshot = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'song.snapshot' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
                if ($reloadedSnapshot.document_epoch -ne $roundTrip.document_epoch -or
                    $reloadedSnapshot.instrument_count -ne 10 -or $reloadedSnapshot.phrase_count -ne 2) {
                    throw 'Reloaded Make Independent inventory did not match the saved native result.'
                }
                Add-Trace -Operation 'acceptance.roundtrip_snapshot' -Status 'PASS' -Details @{ instrument_count = $reloadedSnapshot.instrument_count; phrase_count = $reloadedSnapshot.phrase_count }
                $reopened = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'acid.acceptance.run' -Arguments @{ case = 'reopen-independent' } -TimeoutSeconds ([Math]::Max($CommandTimeoutSeconds, 180)) -ProcessCheck $processCheck
                if ($reopened.case -cne 'reopen-independent' -or [string]$reopened.status -cnotin @('PASS','FAIL','ERROR')) {
                    throw 'Native round-trip acceptance response did not match the fixed case.'
                }
                $scenarioResults.Add([pscustomobject]@{
                    name = 'acceptance.reopen-independent'
                    suite = 'Native'
                    status = [string]$reopened.status
                    expected = 'Saved independent identity and source survive reload, then same-object regeneration succeeds'
                    actual = ConvertTo-AcidCanonicalJson $reopened
                    diff = if ([string]$reopened.status -ceq 'PASS') { $null } else { $reopened }
                })
                Add-Trace -Operation 'acceptance.reopen-independent' -Status ([string]$reopened.status) -Details $reopened
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
        Assert-RenoiseProcessIdentity -Identity $startedIdentity
        $startedProcess.Refresh()
        if (-not $startedProcess.HasExited) {
            [void]$startedProcess.CloseMainWindow()
            if (-not $startedProcess.WaitForExit(10000)) {
                Assert-RenoiseProcessIdentity -Identity $startedIdentity
                Stop-Process -Id $startedIdentity.Id -Force -ErrorAction Stop
                if (-not $startedProcess.WaitForExit(5000)) { throw 'Runner-launched Renoise did not terminate after identity-checked cleanup.' }
                $startedProcessForceStopped = $true
                Add-Trace -Operation 'process.force_stop' -Status 'PASS' -Details @{ runner_launched_process_only = $true; disposable_song_approved = $true }
            }
        }
        $safeToRestore = $true
        $startedProcessClosed = $true
        Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ launched_process_closed_cleanly = (-not $startedProcessForceStopped); force_stopped = $startedProcessForceStopped }
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
    if ($deploymentStarted -and -not $driverMayBeLoaded) {
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
            $startedProcess.Refresh()
            if ($startedProcess.HasExited) {
                $safeToRestore = $true
                Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ runner_launched_process_exited = $true }
            }
            else {
                Assert-RenoiseProcessIdentity -Identity $startedIdentity
                [void]$startedProcess.CloseMainWindow()
                if ($startedProcess.WaitForExit(10000)) {
                    $safeToRestore = $true
                    Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ launched_process_closed_cleanly_after_error = $true }
                }
                else {
                    Assert-RenoiseProcessIdentity -Identity $startedIdentity
                    Stop-Process -Id $startedIdentity.Id -Force -ErrorAction Stop
                    if (-not $startedProcess.WaitForExit(5000)) { throw 'Runner-launched Renoise did not terminate after identity-checked error cleanup.' }
                    $safeToRestore = $true
                    $startedProcessForceStopped = $true
                    Add-Trace -Operation 'process.force_stop' -Status 'PASS' -Details @{ runner_launched_process_only = $true; disposable_song_approved = $true; after_error = $true }
                }
            }
        }
        catch { Add-Trace -Operation 'process.shutdown' -Status 'ERROR' -Details @{ message = $_.Exception.Message } }
    }
    if ($deploymentStarted -and $safeToRestore) {
      try {
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

if ($report.status -eq 'PASS') {
    Write-Output 'PASS interactive Renoise runner'
    exit 0
}
Write-Error "Interactive Renoise runner $($report.status): $($report.error)"
exit 1
