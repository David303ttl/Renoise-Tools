#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'tests/renoise/host_preflight.psm1') -Force
$module = Get-Module host_preflight
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('renoise-preflight-spec-' + [guid]::NewGuid().ToString('N'))
$appData = Join-Path $root 'Roaming'
$tools = Join-Path $appData 'Renoise/V3.5.4/Scripts/Tools'
$exeDirectory = Join-Path $root 'Program Files/Renoise'
$exe = Join-Path $exeDirectory 'Renoise.exe'
$temp = Join-Path $root 'Temp'
$junctionPath = $null
New-Item -ItemType Directory -Path $tools, $exeDirectory, $temp -Force | Out-Null
Set-Content -LiteralPath $exe -Value 'synthetic executable placeholder' -NoNewline
$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$exeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
$selectedProcess = [pscustomobject]@{
    Id = 42
    OwnerSid = $currentSid
    SessionId = 1
    Path = $exe
    StartTimeUtc = '2026-10-29T18:00:00.0000000Z'
}
$configuration = [pscustomobject]@{
    RenoiseExe = $exe
    TemporaryDirectory = $temp
    RenoiseProcessId = 42
    Mode = 'Safety'
}
$context = [pscustomobject]@{
    UserSid = $currentSid
    AppDataPath = $appData
    KnownAppDataPath = $appData
    ProfileAppDataPath = $appData
    UserInteractive = $true
    SessionId = 1
    InteractiveDesktopVerified = $true
    RenoiseProductName = 'Renoise'
    RenoiseCompanyName = 'Renoise'
    RenoiseProductVersion = '3.5.4'
    RenoiseExeSha256 = $exeHash
    RenoiseProcesses = @($selectedProcess)
}
$invokeCore = {
    param($Config, $HostContext)
    & $module {
        param($InnerConfig, $InnerContext)
        Test-RenoiseHostPreflightCore -Configuration $InnerConfig -Context $InnerContext
    } $Config $HostContext
}
$getSnapshot = {
    param([string]$Path)
    @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop |
        ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } |
        Sort-Object)
}
$assertRejectedWithoutWrites = {
    param([string]$Name, $Config, $HostContext)
    $before = @(& $getSnapshot $temp)
    $result = & $invokeCore $Config $HostContext
    if ($result.Passed) { throw "Preflight failed to reject $Name." }
    if ($result.ExecutionAuthorized) { throw "Rejected $Name but authorized execution." }
    $after = @(& $getSnapshot $temp)
    if (Compare-Object $before $after) { throw "Rejected $Name after modifying the temporary directory." }
    Write-Output "PASS rejects $Name without writes"
}

try {
    $result = & $invokeCore $configuration $context
    if (-not $result.Passed -or $result.ExecutionAuthorized -or -not $result.InstallReplacementAuthorized) {
        throw "Valid safety-only context rejected or authorized unexpected actions: $($result.Errors -join '; ')"
    }
    Write-Output 'PASS selected same-session Renoise PID passes safety mode without authorizing execution'

    $publicCommand = Get-Command Test-RenoiseHostPreflight
    if (-not $publicCommand.Parameters.ContainsKey('Mode') -or $publicCommand.Parameters.ContainsKey('Context')) {
        throw 'Public preflight must expose Mode and must not accept caller-supplied Context.'
    }
    $legacyAttestation = [pscustomobject]@{
        RenoiseExe = $exe
        TemporaryDirectory = $temp
        RenoiseProcessId = 42
        DirtyDocumentFlowVerified = $true
        AsyncDocumentLifecycleVerified = $true
        WindowActivationVerified = $true
        DedicatedUserSid = $currentSid
    }
    $before = @(& $getSnapshot $temp)
    $publicResult = Test-RenoiseHostPreflight -Configuration $legacyAttestation -Mode Safety
    if ($publicResult.Passed) { throw 'Public preflight accepted caller-supplied identity or behavior attestations.' }
    if (Compare-Object $before @(& $getSnapshot $temp)) { throw 'Rejected caller attestations after modifying the temporary directory.' }
    Write-Output 'PASS public API rejects caller-supplied identity and behavior attestations'

    $executionWithoutEvidence = [pscustomobject]@{ RenoiseExe = $exe; TemporaryDirectory = $temp; RenoiseProcessId = 42 }
    $before = @(& $getSnapshot $temp)
    $publicResult = Test-RenoiseHostPreflight -Configuration $executionWithoutEvidence
    if ($publicResult.Passed -or $publicResult.ExecutionAuthorized -or
        -not ($publicResult.Errors -join '; ' -match 'Execution mode requires BehaviorEvidencePath')) {
        throw 'Default execution mode did not reject absent behavior evidence.'
    }
    if (Compare-Object $before @(& $getSnapshot $temp)) { throw 'Missing-evidence rejection modified the temporary directory.' }
    Write-Output 'PASS default execution mode requires behavior evidence before writes'

    $badEvidence = Join-Path $temp 'incomplete-evidence.json'
    Set-Content -LiteralPath $badEvidence -Value '{"SchemaVersion":1}' -NoNewline
    $executionConfiguration = $configuration.PSObject.Copy()
    $executionConfiguration.Mode = 'Execution'
    $executionConfiguration | Add-Member -NotePropertyName BehaviorEvidencePath -NotePropertyValue $badEvidence
    & $assertRejectedWithoutWrites 'invalid local behavior evidence' $executionConfiguration $context

    $invalidCases = @(
        @{ Name = 'APPDATA mismatch'; Change = { param($c) $c.AppDataPath = Join-Path $appData 'other-profile' } },
        @{ Name = 'known-folder APPDATA mismatch'; Change = { param($c) $c.KnownAppDataPath = Join-Path $appData 'other-known-folder' } },
        @{ Name = 'registered profile APPDATA mismatch'; Change = { param($c) $c.ProfileAppDataPath = Join-Path $appData 'other-profile' } },
        @{ Name = 'unknown executable metadata'; Change = { param($c) $c.RenoiseProductName = 'Unknown' } },
        @{ Name = 'absent GUI session'; Change = { param($c) $c.UserInteractive = $false } },
        @{ Name = 'unverified active desktop'; Change = { param($c) $c.InteractiveDesktopVerified = $false } },
        @{ Name = 'session zero'; Change = { param($c) $c.SessionId = 0 } },
        @{ Name = 'old Renoise version'; Change = { param($c) $c.RenoiseProductVersion = '3.4.4' } },
        @{ Name = 'executable/profile version mismatch'; Change = { param($c) $c.RenoiseProductVersion = '3.5.3' } },
        @{ Name = 'invalid executable version'; Change = { param($c) $c.RenoiseProductVersion = 'unknown' } }
    )
    foreach ($case in $invalidCases) {
        $candidate = $context.PSObject.Copy()
        & $case.Change $candidate
        & $assertRejectedWithoutWrites $case.Name $configuration $candidate
    }

    $selectedProcessCases = @(
        @{ Name = 'missing selected PID'; Change = { param($c, $x) $c.RenoiseProcessId = 9999 } },
        @{ Name = 'selected PID from another session'; Change = { param($c, $x) $x.RenoiseProcesses[0].SessionId = 2 } },
        @{ Name = 'selected PID executable mismatch'; Change = { param($c, $x) $x.RenoiseProcesses[0].Path = Join-Path $root 'other/Renoise.exe' } },
        @{ Name = 'selected PID owned by another user'; Change = { param($c, $x) $x.RenoiseProcesses[0].OwnerSid = 'S-1-5-21-other' } },
        @{ Name = 'selected PID missing start time'; Change = { param($c, $x) $x.RenoiseProcesses[0].StartTimeUtc = '' } },
        @{ Name = 'unselected active Renoise process'; Change = { param($c, $x) $x.RenoiseProcesses = @($selectedProcess, [pscustomobject]@{ Id = 43; SessionId = 1; Path = $exe; StartTimeUtc = '2026-10-29T18:01:00.0000000Z' }) } },
        @{ Name = 'active Renoise process without selected PID'; Change = { param($c) $c.RenoiseProcessId = 0 } }
    )
    foreach ($case in $selectedProcessCases) {
        $candidateConfiguration = $configuration.PSObject.Copy()
        $candidateContext = $context.PSObject.Copy()
        $candidateContext.RenoiseProcesses = @($context.RenoiseProcesses | ForEach-Object { $_.PSObject.Copy() })
        & $case.Change $candidateConfiguration $candidateContext
        & $assertRejectedWithoutWrites $case.Name $candidateConfiguration $candidateContext
    }

    $noProcessContext = $context.PSObject.Copy()
    $noProcessContext.RenoiseProcesses = @()
    $noProcessConfiguration = $configuration.PSObject.Copy()
    $noProcessConfiguration.RenoiseProcessId = 0
    $noProcessResult = & $invokeCore $noProcessConfiguration $noProcessContext
    if (-not $noProcessResult.Passed -or $noProcessResult.ExecutionAuthorized) {
        throw "Safety mode rejected a clean host with no selected Renoise process: $($noProcessResult.Errors -join '; ')"
    }
    Write-Output 'PASS safety mode permits an idle host with no Renoise process'

    $missingToolsAppData = Join-Path $root 'MissingToolsProfile'
    $missingToolsContext = $context.PSObject.Copy()
    $missingToolsContext.AppDataPath = $missingToolsAppData
    $missingToolsContext.KnownAppDataPath = $missingToolsAppData
    $missingToolsContext.ProfileAppDataPath = $missingToolsAppData
    & $assertRejectedWithoutWrites 'missing versioned Tools directory' $configuration $missingToolsContext

    $fileToolsAppData = Join-Path $root 'FileToolsProfile'
    $fileToolsPath = Join-Path $fileToolsAppData 'Renoise/V3.5.4/Scripts/Tools'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fileToolsPath) -Force | Out-Null
    Set-Content -LiteralPath $fileToolsPath -Value 'not a directory' -NoNewline
    $fileToolsContext = $context.PSObject.Copy()
    $fileToolsContext.AppDataPath = $fileToolsAppData
    $fileToolsContext.KnownAppDataPath = $fileToolsAppData
    $fileToolsContext.ProfileAppDataPath = $fileToolsAppData
    & $assertRejectedWithoutWrites 'Tools path that is a file' $configuration $fileToolsContext

    $version4AppData = Join-Path $root 'Version4Roaming'
    $version4Tools = Join-Path $version4AppData 'Renoise/V4.0.0/Scripts/Tools'
    New-Item -ItemType Directory -Path $version4Tools -Force | Out-Null
    $version4Context = $context.PSObject.Copy()
    $version4Context.AppDataPath = $version4AppData
    $version4Context.KnownAppDataPath = $version4AppData
    $version4Context.ProfileAppDataPath = $version4AppData
    $version4Context.RenoiseProductVersion = '4.0.0'
    $version4Context.RenoiseProcesses[0].Path = $exe
    $version4Result = & $invokeCore $configuration $version4Context
    if (-not $version4Result.Passed) { throw "Matching future major version rejected: $($version4Result.Errors -join '; ')" }
    Write-Output 'PASS accepts exact Renoise 4.x executable/profile alignment'

    $installTarget = Join-Path $tools 'com.david303ttl.ACID.xrnx'
    New-Item -ItemType Directory -Path $installTarget -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installTarget 'unrecognized.txt') -Value 'unowned' -NoNewline
    $unrecognizedResult = & $invokeCore $configuration $context
    if (-not $unrecognizedResult.Passed -or $unrecognizedResult.InstallReplacementAuthorized) {
        throw 'Unrecognized ACID installation was accepted for replacement.'
    }
    Write-Output 'PASS existing unrecognized ACID installation is not authorized for replacement'
    Remove-Item -LiteralPath $installTarget -Recurse -Force

    $sourceBundle = Join-Path $repoRoot 'com.david303ttl.ACID.xrnx'
    Copy-Item -LiteralPath $sourceBundle -Destination $installTarget -Recurse
    $recognizedResult = & $invokeCore $configuration $context
    if (-not $recognizedResult.Passed -or -not $recognizedResult.InstallReplacementAuthorized) {
        throw "Repository-matching ACID bundle was not recognized: $($recognizedResult.Errors -join '; ')"
    }
    Write-Output 'PASS repository-identical ACID bundle is recognized for replacement'
    Set-Content -LiteralPath (Join-Path $installTarget 'manifest.xml') -Value '<tampered />' -NoNewline
    $tamperedResult = & $invokeCore $configuration $context
    if ($tamperedResult.InstallReplacementAuthorized) { throw 'Tampered ACID bundle was authorized for replacement.' }
    Write-Output 'PASS modified ACID bundle is not authorized for replacement'
    Remove-Item -LiteralPath $installTarget -Recurse -Force

    $junctionTarget = Join-Path $root 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionPath = Join-Path $appData 'Renoise'
    Remove-Item -LiteralPath (Join-Path $appData 'Renoise') -Recurse -Force
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    & $assertRejectedWithoutWrites 'versioned Tools directory beneath a junction' $configuration $context
    Remove-Item -LiteralPath $junctionPath -Force
    $junctionPath = $null

    $installJunction = Join-Path $tools 'com.david303ttl.ACID.xrnx'
    New-Item -ItemType Junction -Path $installJunction -Target $sourceBundle | Out-Null
    $junctionResult = & $invokeCore $configuration $context
    if ($junctionResult.InstallReplacementAuthorized) { throw 'Junction at the ACID target was authorized for replacement.' }
    Write-Output 'PASS junction at ACID install target cannot authorize replacement'
    Remove-Item -LiteralPath $installJunction -Force
    $installJunction = $null

    $validObservations = & $module {
        param($Sid, $AppData, $Version, $ExeHash, $Process)
        $api = [System.Collections.Generic.List[object]]::new()
        foreach ($operation in @('new_song','load_song')) {
            foreach ($choice in @('Cancel','Save','Discard')) {
                $api.Add([pscustomobject]@{ flow='dirty_document'; event=('dirty_prompt_' + $choice.ToLowerInvariant()); result='observed'; details="operation=$operation;choice=$choice" })
            }
        }
        foreach ($eventName in @('request_new_song','request_load_song')) { $api.Add([pscustomobject]@{ flow='async_document_lifecycle'; event=$eventName; result='requested'; details='' }) }
        foreach ($eventName in @('app_release_document','app_saved_document','clean_lifecycle_probe_complete','tool_will_unload','tool_finished_loading')) { $api.Add([pscustomobject]@{ flow='async_document_lifecycle'; event=$eventName; result='observed'; details='' }) }
        $api.Add([pscustomobject]@{ flow='async_document_lifecycle'; event='app_new_document'; result='observed'; details='generationAdvanced=true' })
        $foreground = foreach ($state in @('foreground','background','foreground')) {
            [pscustomobject]@{ flow='window_activation'; result='observed'; details=[pscustomobject]@{ state=$state; userSid=$Sid; appDataPath=$AppData; sessionId=$Process.SessionId; targetProcessId=$Process.Id; targetProcessStartTimeUtc=$Process.StartTimeUtc; targetExecutablePath=$Process.Path; targetExecutableSha256=$ExeHash } }
        }
        $live = [pscustomobject]@{ UserSid=$Sid; AppDataPath=$AppData; SessionId=$Process.SessionId; RenoiseExeSha256=$ExeHash }
        Test-SpikeObservations -ApiRecords $api.ToArray() -ForegroundRecords @($foreground) -Context $live -SelectedProcess $Process
    } $currentSid $appData '3.5.4' $exeHash $selectedProcess
    if (-not $validObservations.Passed) { throw "Valid synthetic host observations rejected: $($validObservations.Errors -join '; ')" }
    Write-Output 'PASS behavior observations cover dirty choices, document lifecycle, and foreground return'

    foreach ($mutation in @('missing dirty choice','missing release event','missing document generation','foreign foreground PID','missing foreground return')) {
        $invalidObservations = & $module {
            param($Sid, $AppData, $ExeHash, $Process, $Mutation)
            $api = [System.Collections.Generic.List[object]]::new()
            foreach ($operation in @('new_song','load_song')) {
                foreach ($choice in @('Cancel','Save','Discard')) {
                    if ($Mutation -eq 'missing dirty choice' -and $operation -eq 'load_song' -and $choice -eq 'Discard') { continue }
                    $api.Add([pscustomobject]@{ flow='dirty_document'; event=('dirty_prompt_' + $choice.ToLowerInvariant()); result='observed'; details="operation=$operation;choice=$choice" })
                }
            }
            foreach ($eventName in @('request_new_song','request_load_song')) { $api.Add([pscustomobject]@{ flow='async_document_lifecycle'; event=$eventName; result='requested'; details='' }) }
            foreach ($eventName in @('app_release_document','app_saved_document','clean_lifecycle_probe_complete','tool_will_unload','tool_finished_loading')) {
                if ($Mutation -eq 'missing release event' -and $eventName -eq 'app_release_document') { continue }
                $api.Add([pscustomobject]@{ flow='async_document_lifecycle'; event=$eventName; result='observed'; details='' })
            }
            $change = if ($Mutation -eq 'missing document generation') { 'generationAdvanced=false' } else { 'generationAdvanced=true' }
            $api.Add([pscustomobject]@{ flow='async_document_lifecycle'; event='app_new_document'; result='observed'; details=$change })
            $states = if ($Mutation -eq 'missing foreground return') { @('foreground','background') } else { @('foreground','background','foreground') }
            $foreground = foreach ($state in $states) {
                $pidValue = if ($Mutation -eq 'foreign foreground PID') { 999 } else { $Process.Id }
                [pscustomobject]@{ flow='window_activation'; result='observed'; details=[pscustomobject]@{ state=$state; userSid=$Sid; appDataPath=$AppData; sessionId=$Process.SessionId; targetProcessId=$pidValue; targetProcessStartTimeUtc=$Process.StartTimeUtc; targetExecutablePath=$Process.Path; targetExecutableSha256=$ExeHash } }
            }
            $live = [pscustomobject]@{ UserSid=$Sid; AppDataPath=$AppData; SessionId=$Process.SessionId; RenoiseExeSha256=$ExeHash }
            Test-SpikeObservations -ApiRecords $api.ToArray() -ForegroundRecords @($foreground) -Context $live -SelectedProcess $Process
        } $currentSid $appData $exeHash $selectedProcess $mutation
        if ($invalidObservations.Passed) { throw "Behavior observation validator accepted '$mutation'." }
        Write-Output "PASS behavior evidence rejects $mutation"
    }
}
finally {
    if ($installJunction -and (Test-Path -LiteralPath $installJunction)) { Remove-Item -LiteralPath $installJunction -Force }
    if ($junctionPath -and (Test-Path -LiteralPath $junctionPath)) { Remove-Item -LiteralPath $junctionPath -Force }
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $cleanupRoot = [System.IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $temporaryPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $cleanupRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($cleanupRoot) -notmatch '^renoise-preflight-spec-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected preflight test directory '$cleanupRoot'."
    }
    Remove-Item -LiteralPath $cleanupRoot -Recurse -Force
}
