#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../tests/renoise/host_preflight.psm1" -Force
$module = Get-Module host_preflight
$root = Join-Path ([IO.Path]::GetTempPath()) ('renoise-preflight-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $exe = Join-Path $root 'Renoise.exe'
    Set-Content $exe 'fixture'
    $config = [pscustomobject]@{ RenoiseExe=$exe; TemporaryDirectory=$root; RenoiseProcessId=42; Mode='Safety' }
    $context = [pscustomobject]@{
        RenoiseProductVersion='3.5.4'
        RenoiseProcesses=@([pscustomobject]@{Id=42; Path=$exe; StartTimeUtc=[datetime]::UtcNow})
    }
    function Check($Name, $Configuration, $Context, $Expected) {
        $result = & $module { param($C,$X) Test-RenoiseHostPreflightCore $C $X } $Configuration $Context
        if ($result.Passed -ne $Expected) { throw "${Name}: $($result.Errors -join '; ')" }
        Write-Output "PASS $Name"
    }
    Check 'selected PID readiness without desktop, profile or evidence data' $config $context $true
    $fresh=$config.PSObject.Copy(); $fresh.RenoiseProcessId=0
    Check 'fresh launch with existing instances' $fresh $context $true
    $other=$context.PSObject.Copy()
    $other.RenoiseProcesses=@($context.RenoiseProcesses)+@([pscustomobject]@{Id=43;Path='other';StartTimeUtc=[datetime]::UtcNow})
    Check 'other instances do not block selected process' $config $other $true
    $execution=$config.PSObject.Copy();$execution.Mode='Execution'
    Check 'legacy execution mode needs no trace evidence' $execution $context $true
    $bad=$config.PSObject.Copy();$bad.RenoiseProcessId=999
    Check 'missing selected PID' $bad $context $false
    $bad=$context.PSObject.Copy();$bad.RenoiseProcesses=@([pscustomobject]@{Id=42;Path=(Join-Path $root 'other.exe');StartTimeUtc=[datetime]::UtcNow})
    Check 'wrong executable' $config $bad $false
    $bad=$context.PSObject.Copy();$bad.RenoiseProductVersion='3.4.4'
    Check 'unsupported Renoise version' $config $bad $false
    $bad=$config.PSObject.Copy();$bad.TemporaryDirectory=Join-Path $root 'missing'
    Check 'missing temporary directory' $bad $context $false
    $bad=$config.PSObject.Copy();$bad.RenoiseExe=Join-Path $root 'missing.exe'
    Check 'missing executable' $bad $context $false
    $link=Join-Path $root 'linked-temp'
    New-Item -ItemType Junction -Path $link -Target $root | Out-Null
    try {
        $linked=$config.PSObject.Copy();$linked.TemporaryDirectory=$link
        Check 'linked temporary path is supported' $linked $context $true
    } finally { Remove-Item -LiteralPath $link -Force }
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
