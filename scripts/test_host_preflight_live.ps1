#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RenoiseExe, [int]$RenoiseProcessId = 0,
      [string]$BehaviorEvidencePath, [switch]$RequireSafetyPass)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../tests/renoise/host_preflight.psm1" -Force
$result = Test-RenoiseHostPreflight -Configuration ([pscustomobject]@{
    RenoiseExe=$RenoiseExe; RenoiseProcessId=$RenoiseProcessId; TemporaryDirectory=[IO.Path]::GetTempPath()
})
if (-not $result.Passed) { throw ($result.Errors -join '; ') }
Write-Output 'PASS executable, selected process and temporary directory readiness'
