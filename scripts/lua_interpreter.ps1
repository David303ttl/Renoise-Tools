#Requires -Version 7.0

function Assert-LuaLanguageVersion {
    param([string]$Version)

    if ($Version -notmatch '^Lua (\d+)\.(\d+)$') {
        throw "Cannot determine Lua language version from _VERSION: $Version."
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 5 -or ($major -eq 5 -and $minor -lt 1)) {
        throw "Lua 5.1 or newer is required; _VERSION reports $Version."
    }
}

function Resolve-LuaInterpreter {
    param([string]$LuaCommand = 'lua')

    $command = Get-Command -Name $LuaCommand -CommandType Application -ErrorAction Stop
    $output = @(& $command.Source -e 'print(_VERSION)' 2>&1)
    $exitCode = $LASTEXITCODE
    $version = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "Cannot query _VERSION for '$LuaCommand': $version (exit $exitCode)."
    }
    Assert-LuaLanguageVersion -Version $version
    Write-Host "Lua interpreter: $($command.Source) ($version)"
    return [pscustomobject]@{ Source = $command.Source; Version = $version }
}
