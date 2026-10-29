#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'tests/renoise/host_preflight.psm1') -Force
$preflightModule = Get-Module host_preflight
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('renoise-preflight-spec-' + [guid]::NewGuid().ToString('N'))
$appData = Join-Path $root 'Roaming'
$tools = Join-Path $appData 'Renoise/V3.5.4/Scripts/Tools'
$marker = Join-Path $appData '.renoise-test-profile'
$exeDirectory = Join-Path $root 'Program Files/Renoise'
$exe = Join-Path $exeDirectory 'Renoise.exe'
$temp = Join-Path $root 'Temp'
$junctionPath = $null
$installJunction = $null
New-Item -ItemType Directory -Path $tools, $exeDirectory, $temp -Force | Out-Null
Set-Content -LiteralPath $marker -Value 'dedicated-test-profile' -NoNewline
Set-Content -LiteralPath $exe -Value 'synthetic executable placeholder' -NoNewline
$configuration = [pscustomobject]@{
    DedicatedUserSid = 'S-1-5-21-test'
    DedicatedSessionId = 1
    ProfileMarkerPath = $marker
    ProfileMarkerValue = 'dedicated-test-profile'
    RenoiseExe = $exe
    AppDataPath = $appData
    ToolsPath = $tools
    ToolInstallPath = Join-Path $tools 'com.david303ttl.ACID.xrnx'
    TemporaryDirectory = $temp
    DirtyDocumentFlowVerified = $true
    AsyncDocumentLifecycleVerified = $true
    WindowActivationVerified = $true
}
$context = [pscustomobject]@{
    UserSid = 'S-1-5-21-test'
    AppDataPath = $appData
    KnownAppDataPath = $appData
    UserInteractive = $true
    SessionId = 1
    InteractiveDesktopVerified = $true
    RenoiseProductName = 'Renoise'
    RenoiseCompanyName = 'Renoise'
    RenoiseProductVersion = '3.5.4'
    RenoiseProcesses = @()
}
$invokeCore = {
    param($Config, $HostContext)
    & $preflightModule {
        param($InnerConfig, $InnerContext)
        Test-RenoiseHostPreflightCore -Configuration $InnerConfig -Context $InnerContext
    } $Config $HostContext
}
try {
    $result = & $invokeCore $configuration $context
    if (-not $result.Passed) { throw "Valid isolated-host context rejected: $($result.Errors -join '; ')" }

    $publicCommand = Get-Command Test-RenoiseHostPreflight
    if ($publicCommand.Parameters.ContainsKey('Context')) { throw 'Public preflight exposes a caller-supplied Context parameter.' }
    Write-Output 'PASS public preflight does not accept fabricated host context'

    foreach ($requiredField in @('DedicatedSessionId', 'DirtyDocumentFlowVerified', 'AsyncDocumentLifecycleVerified', 'WindowActivationVerified')) {
        $incompleteConfiguration = $configuration.PSObject.Copy()
        $incompleteConfiguration.PSObject.Properties.Remove($requiredField)
        $before = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
        $result = & $invokeCore $incompleteConfiguration $context
        if ($result.Passed) { throw "Preflight accepted configuration without '$requiredField'." }
        if ($requiredField -in @('DirtyDocumentFlowVerified', 'AsyncDocumentLifecycleVerified', 'WindowActivationVerified')) {
            $publicResult = Test-RenoiseHostPreflight -Configuration $incompleteConfiguration
            if ($publicResult.Passed) { throw "Public preflight accepted missing '$requiredField'." }
        }
        $after = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
        if (Compare-Object $before $after) { throw "Missing '$requiredField' modified the temporary directory." }
        Write-Output "PASS rejects missing $requiredField without writes"
    }
    foreach ($attestation in @('DirtyDocumentFlowVerified', 'AsyncDocumentLifecycleVerified', 'WindowActivationVerified')) {
        $falseConfiguration = $configuration.PSObject.Copy()
        $falseConfiguration.$attestation = $false
        $before = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
        $publicResult = Test-RenoiseHostPreflight -Configuration $falseConfiguration
        if ($publicResult.Passed) { throw "Public preflight accepted false '$attestation'." }
        $after = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
        if (Compare-Object $before $after) { throw "False '$attestation' modified the temporary directory." }
        Write-Output "PASS public preflight rejects false $attestation without writes"
    }

    $cases = @(
        @{ Name = 'normal user identity'; Change = { param($c) $c.UserSid = 'S-1-5-21-normal' } },
        @{ Name = 'APPDATA mismatch'; Change = { param($c, $x) $c.AppDataPath = Join-Path $x.AppDataPath 'other-profile' } },
        @{ Name = 'ApplicationData known-folder mismatch'; Change = { param($c, $x) $c.KnownAppDataPath = Join-Path $x.AppDataPath 'other-known-folder' } },
        @{ Name = 'unknown executable metadata'; Change = { param($c) $c.RenoiseProductName = 'Unknown' } },
        @{ Name = 'absent GUI session'; Change = { param($c) $c.UserInteractive = $false } },
        @{ Name = 'unverified active desktop'; Change = { param($c) $c.InteractiveDesktopVerified = $false } },
        @{ Name = 'unexpected GUI session'; Change = { param($c) $c.SessionId = 2 } },
        @{ Name = 'unsafe Tools path'; Change = { param($c, $x) $x.ToolsPath = Join-Path $x.AppDataPath 'Renoise/Scripts/Tools'; $x.ToolInstallPath = Join-Path $x.ToolsPath 'com.david303ttl.ACID.xrnx' } },
        @{ Name = 'unexpected existing Renoise process'; Change = { param($c) $c.RenoiseProcesses = @([pscustomobject]@{ Id = 1234 }) } },
        @{ Name = 'old Renoise version'; Change = { param($c) $c.RenoiseProductVersion = '3.4.4' } },
        @{ Name = 'unresolved profile marker'; Change = { param($c, $x) $x.ProfileMarkerValue = 'other' } },
        @{ Name = 'unverified dirty-document flow'; Change = { param($c, $x) $x.DirtyDocumentFlowVerified = $false } },
        @{ Name = 'unverified async document lifecycle'; Change = { param($c, $x) $x.AsyncDocumentLifecycleVerified = $false } },
        @{ Name = 'unverified window activation'; Change = { param($c, $x) $x.WindowActivationVerified = $false } }
    )
    foreach ($case in $cases) {
        $before = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
        $candidate = $configuration.PSObject.Copy()
        $candidateContext = $context.PSObject.Copy()
        & $case.Change $candidateContext $candidate
        $result = & $invokeCore $candidate $candidateContext
        if ($result.Passed) { throw "Preflight failed to reject $($case.Name)." }
        $after = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
        if (Compare-Object $before $after) { throw "Rejected $($case.Name) after modifying the temporary directory." }
        Write-Output "PASS rejects $($case.Name)"
    }

    $junctionAppData = Join-Path $root 'junction-appdata'
    New-Item -ItemType Directory -Path $junctionAppData -Force | Out-Null
    $junctionMarker = Join-Path $junctionAppData '.renoise-test-profile'
    Set-Content -LiteralPath $junctionMarker -Value 'dedicated-test-profile' -NoNewline
    $junctionTarget = Join-Path $root 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionPath = Join-Path $junctionAppData 'Renoise'
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    $junctionConfiguration = $configuration.PSObject.Copy()
    $junctionConfiguration.AppDataPath = $junctionAppData
    $junctionConfiguration.ProfileMarkerPath = $junctionMarker
    $junctionConfiguration.ToolsPath = Join-Path $junctionPath 'V3.5.4/Scripts/Tools'
    $junctionConfiguration.ToolInstallPath = Join-Path $junctionConfiguration.ToolsPath 'com.david303ttl.ACID.xrnx'
    $junctionContext = $context.PSObject.Copy()
    $junctionContext.AppDataPath = $junctionAppData
    $junctionContext.KnownAppDataPath = $junctionAppData
    $before = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
    $result = & $invokeCore $junctionConfiguration $junctionContext
    if ($result.Passed) { throw 'Preflight accepted missing Tools leaf beneath a junction.' }
    $after = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
    if (Compare-Object $before $after) { throw 'Junction preflight modified the temporary directory.' }
    Write-Output 'PASS rejects missing Tools leaf beneath a junction'
    Remove-Item -LiteralPath $junctionPath -Force
    $junctionPath = $null

    $installTarget = Join-Path $root 'install-target'
    New-Item -ItemType Directory -Path $installTarget -Force | Out-Null
    $installJunction = Join-Path $tools 'com.david303ttl.ACID.xrnx'
    New-Item -ItemType Junction -Path $installJunction -Target $installTarget | Out-Null
    $before = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
    $result = & $invokeCore $configuration $context
    if ($result.Passed) { throw 'Preflight accepted a junction at ToolInstallPath.' }
    $after = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object FullName | Sort-Object)
    if (Compare-Object $before $after) { throw 'ToolInstallPath junction preflight modified the temporary directory.' }
    Write-Output 'PASS rejects junction at ToolInstallPath'
    Remove-Item -LiteralPath $installJunction -Force
    $installJunction = $null
}
finally {
    if ($installJunction -and (Test-Path -LiteralPath $installJunction)) { Remove-Item -LiteralPath $installJunction -Force }
    if ($junctionPath -and (Test-Path -LiteralPath $junctionPath)) { Remove-Item -LiteralPath $junctionPath -Force }
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $cleanupRoot = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $temporaryPrefix = $temporaryRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $cleanupRoot.StartsWith($temporaryPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($cleanupRoot) -notmatch '^renoise-preflight-spec-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected preflight test directory '$cleanupRoot'."
    }
    Remove-Item -LiteralPath $cleanupRoot -Recurse -Force
}
