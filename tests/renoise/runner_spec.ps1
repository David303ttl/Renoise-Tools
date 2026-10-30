#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/runner.psm1" -Force
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected rejection: $Pattern"
}
$keyboardEnvironment = '{"Keyboard":{"ShowShortcut":"^!a","TimeoutSeconds":3}}' | ConvertFrom-Json -AsHashtable
$keyboardConfiguration = Get-AcidKeyboardConfiguration -Environment ([pscustomobject]$keyboardEnvironment)
Assert ($keyboardConfiguration.ShowShortcut -ceq '^!a' -and $keyboardConfiguration.TimeoutSeconds -eq 3) 'keyboard developer configuration did not load'
Reject { Get-AcidKeyboardConfiguration -Environment ([pscustomobject]@{ Keyboard = [ordered]@{ ShowShortcut = '^!b'; TimeoutSeconds = 31 } }) } 'integer from 1 to 30'
Reject { Get-AcidKeyboardConfiguration -Environment ([pscustomobject]@{ Keyboard = [ordered]@{} }) } 'Keyboard mapping is missing'
Reject { Get-AcidKeyboardConfiguration -Environment ([pscustomobject]@{ Keyboard = [ordered]@{ ShowShortcut = 'not a key' } }) } 'AutoHotkey v2 key sequence'
Reject { Wait-AcidObservedState -ReadState { [pscustomobject]@{ visible = $false } } -Condition { param($state) $false } -ProcessCheck {} -TimeoutSeconds 1 -PollMilliseconds 50 } 'Timed out after 1 seconds'
# A separate runspace supplies real fragmented TCP responses without Renoise.
foreach ($mode in @('valid','wrong','invalid','string-ok','numeric-ok','missing-ok','missing-result','false-missing-error','lost','timeout','shutdown','shutdown-missing')) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $client = Connect-RenoiseDriver -Session ([pscustomobject]@{Port=$listener.LocalEndpoint.Port}) -TimeoutSeconds 2 -ProcessCheck {}
    Assert ($client -is [Net.Sockets.TcpClient]) 'connector returned unexpected pipeline output'
    $peer = $listener.AcceptTcpClient()
    $worker = [PowerShell]::Create()
    $sessionPath = Join-Path ([IO.Path]::GetTempPath()) ('runner-stop-' + [guid]::NewGuid().ToString('N'))
    $session = [pscustomobject]@{Token='test';Nonce='test-run-nonce'}
    [void]$worker.AddScript({ param($Peer,$Mode,$SessionPath,$Nonce)
        $stream = $Peer.GetStream()
        $reader = [IO.StreamReader]::new($stream)
        $request = $reader.ReadLine() | ConvertFrom-Json
        if ($Mode -eq 'lost') { $Peer.Dispose(); return }
        if ($Mode -eq 'timeout') { Start-Sleep -Seconds 2; return }
        $id = if ($Mode -eq 'wrong') { 'wrong' } else { $request.id }
        $result = if ($Mode -like 'shutdown*') { @{shutdown_requested=$true} } else { @{value=42} }
        $ok = if ($Mode -eq 'string-ok') { 'true' } elseif ($Mode -eq 'numeric-ok') { 1 } elseif ($Mode -eq 'false-missing-error') { $false } else { $true }
        $envelope = @{id=$id;ok=$ok;result=$result}
        if ($Mode -eq 'missing-ok') { $envelope.Remove('ok') }
        if ($Mode -eq 'missing-result') { $envelope.Remove('result') }
        $line = if ($Mode -eq 'invalid') { "bad-json`n" } else { ($envelope | ConvertTo-Json -Compress) + "`n" }
        foreach ($byte in [Text.Encoding]::UTF8.GetBytes($line)) { $stream.WriteByte($byte); $stream.Flush(); Start-Sleep -Milliseconds 2 }
        if ($Mode -eq 'shutdown') { [IO.File]::WriteAllText($SessionPath + '.' + $Nonce + '.stopped', $Nonce) }
    }).AddArgument($peer).AddArgument($mode).AddArgument($sessionPath).AddArgument($session.Nonce)
    $pending = $worker.BeginInvoke()
    try {
        $action = { Invoke-RenoiseDriverRequest -Client $client -Session ([pscustomobject]@{Token='test'}) -Operation ping -Arguments @{} -TimeoutSeconds $(if ($mode -eq 'timeout') { 1 } else { 5 }) -ProcessCheck {} }
        if ($mode -eq 'shutdown') {
            Assert (Stop-RenoiseDriver -Client $client -Session $session -SessionPath $sessionPath -TimeoutSeconds 5 -ProcessCheck {}) 'shutdown completion not verified'
            Assert (-not (Test-Path ($sessionPath + '.' + $session.Nonce + '.stopped'))) 'shutdown marker not cleaned'
        }
        elseif ($mode -eq 'shutdown-missing') {
            Reject { Stop-RenoiseDriver -Client $client -Session $session -SessionPath $sessionPath -TimeoutSeconds 5 -ProcessCheck {} } 'finish shutdown'
        }
        elseif ($mode -eq 'valid') { Assert ((& $action).value -eq 42) 'fragmented response failed' }
        else { Reject $action (@{wrong='unexpected request ID';invalid='JSON';'string-ok'='invalid response envelope';'numeric-ok'='invalid response envelope';'missing-ok'='invalid response envelope';'missing-result'='invalid response envelope';'false-missing-error'='invalid response envelope';lost='closed the transport';timeout='Timed out'}[$mode]) }
        $identity = [pscustomobject]@{Id=123;StartTimeUtc=[datetime]::UtcNow}
        Assert-RenoiseListenerOwner -Client $client -Identity $identity -CheckIdentity {} -GetListeners { param($Port) [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=123} }
        Reject { Assert-RenoiseListenerOwner -Client $client -Identity $identity -CheckIdentity {} -GetListeners { [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=456} } } 'ownership'
    } finally { $client.Dispose(); $listener.Stop(); $worker.EndInvoke($pending); $worker.Dispose(); $peer.Dispose() }
}
$closedListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$closedListener.Start()
$closedPort = $closedListener.LocalEndpoint.Port
$closedListener.Stop()
$checkCounter = [pscustomobject]@{ Count = 0 }
Reject { Connect-RenoiseDriver -Session ([pscustomobject]@{Port=$closedPort}) -TimeoutSeconds 1 -ProcessCheck { $checkCounter.Count++ } } 'Timed out.*loopback listener'
Assert ($checkCounter.Count -gt 0) 'startup retry did not revalidate the selected Renoise process'
$scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) ('runner-scenarios-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scenarioRoot | Out-Null
try {
    $scenarioJson = '{"name":"fixture-a","fixture":"alpha.xrns","preconditions":{"instrument_count":1,"phrase_count":1},"actions":["document.new","fixture.load","song.snapshot","song.snapshot"],"waits":["document.changed","inventory.settled","snapshot.stable"],"unchanged":["selected_instrument_index"],"assertions":[{"path":"instrument_count","expected":1},{"path":"instruments.0.phrases.0.properties.name","expected":"Independent phrase"},{"path":"tool_data_hex","expected":null}]}'
    [IO.File]::WriteAllText((Join-Path $scenarioRoot 'fixture-a.json'), $scenarioJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $scenarioRoot 'alpha.xrns'), 'fixture')
    $catalog = Get-AcidScenarioCatalog -Directory $scenarioRoot
    Assert ($catalog.Count -eq 1 -and $catalog[0].fixture -ceq 'alpha.xrns') 'scenario catalog failed to load stable fixture definition'
    $selection = @(Get-AcidInteractiveScenarioSelection -Scenario 'fixture-a' -Directory $scenarioRoot)
    Assert ($selection.Count -eq 1 -and $selection[0].name -ceq 'fixture-a') 'interactive scenario selection did not resolve a registered scenario'
    $defaultSelection = @(Get-AcidInteractiveScenarioSelection -Directory $scenarioRoot)
    Assert ($defaultSelection.Count -eq 1 -and $defaultSelection[0].name -ceq 'fixture-a') 'default interactive scenario selection returned a nested catalog array'
    Assert ((Assert-AcidScenarioFixtures -Directory $scenarioRoot -Scenarios $catalog) -eq 1) 'catalog selection did not resolve its staged fixture'
    $snapshot = @{ instrument_count = 1; instruments = @(@{ phrases = @(@{ properties = @{ name = 'Independent phrase' } }) }); tool_data_hex = $null }
    $comparison = Compare-AcidScenarioSnapshot -Scenario $catalog[0] -Snapshot $snapshot
    Assert $comparison.passed 'independent scenario golden did not match observed snapshot'
    $canonicalOrdering = ConvertTo-AcidCanonicalJson ('{"z":1,"ä":2,"a":3}' | ConvertFrom-Json -AsHashtable)
    Assert ($canonicalOrdering -ceq '{"a":3,"z":1,"ä":2}') 'canonical object keys were not sorted with ordinal ordering'
    $nestedArrayValue = '{"empty":[],"single_null":[null],"nested":[1,null,[],[2]]}' | ConvertFrom-Json -AsHashtable
    $nestedArrayCanonical = ConvertTo-AcidCanonicalJson $nestedArrayValue
    Assert ($nestedArrayCanonical -ceq '{"empty":[],"nested":[1,null,[],[2]],"single_null":[null]}') 'canonicalization changed empty, singleton-null, or nested array values'
    Assert ((ConvertTo-AcidCanonicalJson @{}) -ceq '{}') 'canonicalization rejected an empty dictionary'
    Assert ((ConvertTo-AcidCanonicalJson ([pscustomobject]@{})) -ceq '{}') 'canonicalization rejected an empty object'
    $failureExpected = @(@{ path = 'instrument_count'; expected = 99 })
    $failure = Compare-AcidScenarioSnapshot -Scenario $catalog[0] -Snapshot $snapshot -Assertions $failureExpected
    Assert (-not $failure.passed -and $failure.diff.Count -eq 1) 'deliberate assertion failure did not produce one exact mismatch'
    Assert ($failure.diff[0].path -ceq 'instrument_count' -and $failure.diff[0].expected -eq 99 -and $failure.diff[0].actual -eq 1) 'deliberate failure diff lost expected/actual values'
    $missing = Get-AcidSnapshotPathValue -Snapshot $snapshot -Path 'instruments.1.phrases.0.properties.name'
    Assert (-not $missing.Found) 'missing snapshot field was treated as present'
} finally {
    Remove-Item -LiteralPath $scenarioRoot -Recurse -Force
}
$missingCatalogPath = Join-Path ([IO.Path]::GetTempPath()) ('runner-missing-catalog-' + [guid]::NewGuid().ToString('N'))
$transportSelection = @(Get-AcidInteractiveScenarioSelection -Scenario 'transport' -Directory $missingCatalogPath)
Assert ($transportSelection.Count -eq 0) 'transport-only selection required the native scenario directory'
$malformedCatalogRoot = Join-Path ([IO.Path]::GetTempPath()) ('runner-malformed-catalog-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $malformedCatalogRoot | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $malformedCatalogRoot 'broken.json'), '{', [Text.UTF8Encoding]::new($false))
    $transportSelection = @(Get-AcidInteractiveScenarioSelection -Scenario 'transport' -Directory $malformedCatalogRoot)
    Assert ($transportSelection.Count -eq 0) 'transport-only selection parsed the malformed native catalog'
    Reject { Get-AcidInteractiveScenarioSelection -Scenario 'broken' -Directory $malformedCatalogRoot } '.+'
} finally {
    Remove-Item -LiteralPath $malformedCatalogRoot -Recurse -Force
}
 $fixturePreflightRoot = Join-Path ([IO.Path]::GetTempPath()) ('runner-fixtures-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $fixturePreflightRoot | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $fixturePreflightRoot 'alpha.xrns'), 'fixture')
    Assert ((Assert-AcidScenarioFixtures -Directory $fixturePreflightRoot -Scenarios @(@{ name='alpha'; fixture='alpha.xrns' })) -eq 1) 'staged fixture preflight did not accept a registered fixture'
    Reject { Assert-AcidScenarioFixtures -Directory $fixturePreflightRoot -Scenarios @(@{ name='missing'; fixture='missing.xrns' }) } 'requires missing staged fixture'
} finally {
    Remove-Item -LiteralPath $fixturePreflightRoot -Recurse -Force
}
function Reject-ScenarioJson([string]$Json, [string]$Pattern) {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('runner-catalog-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $directory | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $directory 'case.json'), $Json, [Text.UTF8Encoding]::new($false))
        Reject { Get-AcidScenarioCatalog -Directory $directory } $Pattern
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}
$baseScenario = '{"name":"alpha","fixture":"alpha.xrns","preconditions":{"instrument_count":1,"phrase_count":0},"actions":["document.new","fixture.load","song.snapshot","song.snapshot"],"waits":["document.changed","inventory.settled","snapshot.stable"],"unchanged":["selected_instrument_index"],"assertions":[{"path":"instrument_count","expected":1}]}'
Reject-ScenarioJson ($baseScenario.TrimEnd('}') + ',"unknown":true}') 'unknown key'
Reject-ScenarioJson ($baseScenario.TrimEnd('}') + ',"expects":"maybe"}') 'expects must'
Reject-ScenarioJson ($baseScenario.TrimEnd('}') + ',"expects":"fail"}') 'requires non-empty expected_diffs'
Reject-ScenarioJson ($baseScenario.TrimEnd('}') + ',"expected_diffs":[{"path":"instrument_count","expected":1,"actual":2}]}') 'only allowed when expects'
Reject-ScenarioJson ($baseScenario.Replace('"preconditions":{"instrument_count":1,"phrase_count":0}', '"preconditions":{"instrument_count":1,"phrase_count":0,"unknown":2}')) 'unknown key'
Reject-ScenarioJson ($baseScenario.Replace('"phrase_count":0', '"phrase_count":-1')) 'non-negative integer'
Reject-ScenarioJson ($baseScenario.Replace('"instrument_count":1', '"instrument_count":1.5')) 'non-negative integer'
Reject-ScenarioJson ('{"name":"missing-fields","fixture":"alpha.xrns","assertions":[{"path":"instrument_count","expected":1}]}') 'malformed'
Reject-ScenarioJson ('{"name":"duplicate-assertion","fixture":"alpha.xrns","preconditions":{"instrument_count":1,"phrase_count":0},"actions":["document.new","fixture.load","song.snapshot","song.snapshot"],"waits":["document.changed","inventory.settled","snapshot.stable"],"unchanged":["selected_instrument_index"],"assertions":[{"path":"instrument_count","expected":1},{"path":"instrument_count","expected":1}]}') 'assertion paths must be unique'
Reject-ScenarioJson ('{"name":"duplicate-diff","fixture":"alpha.xrns","preconditions":{"instrument_count":1,"phrase_count":0},"actions":["document.new","fixture.load","song.snapshot","song.snapshot"],"waits":["document.changed","inventory.settled","snapshot.stable"],"unchanged":["selected_instrument_index"],"expects":"fail","expected_diffs":[{"path":"instrument_count","expected":1,"actual":2},{"path":"instrument_count","expected":1,"actual":2}],"assertions":[{"path":"instrument_count","expected":1}]}') 'expected diff paths must be unique'
$extendedScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) ('runner-catalog-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $extendedScenarioRoot | Out-Null
try {
    $extendedJson = '{"name":"beta","fixture":"beta.xrns","description":"documented","preconditions":{"instrument_count":0,"phrase_count":0},"actions":["document.new","fixture.load","song.snapshot","song.snapshot"],"waits":["document.changed","inventory.settled","snapshot.stable"],"unchanged":["selected_instrument_index"],"expects":"fail","expected_diffs":[{"path":"instrument_count","expected":1,"actual":2}],"assertions":[{"path":"instruments.0.phrases.0.name","expected":"Independent phrase"}]}'
    [IO.File]::WriteAllText((Join-Path $extendedScenarioRoot 'beta.json'), $extendedJson, [Text.UTF8Encoding]::new($false))
    $extendedCatalog = @(Get-AcidScenarioCatalog -Directory $extendedScenarioRoot)
    Assert ($extendedCatalog.Count -eq 1 -and $extendedCatalog[0].expects -ceq 'fail') 'extended scenario metadata was not retained'
    Assert ($extendedCatalog[0].description -ceq 'documented' -and $extendedCatalog[0].preconditions.instrument_count -eq 0) 'optional scenario metadata was not retained'
} finally {
    Remove-Item -LiteralPath $extendedScenarioRoot -Recurse -Force
}
function New-ScenarioSnapshot {
    param(
        [int]$InstrumentCount = 1,
        [bool]$CanUndo = $false,
        [bool]$CanRedo = $false,
        [bool]$Undoing = $false,
        [int]$SelectedInstrument = 1,
        [int]$SelectedPhrase = 0
    )
    return @{
        instrument_count = $InstrumentCount
        phrase_count = 0
        selected_instrument_index = $SelectedInstrument
        selected_phrase_index = $SelectedPhrase
        can_undo = $CanUndo
        can_redo = $CanRedo
        is_undo_redoing = $Undoing
        instruments = @()
    }
}
function New-FakeScenarioDriver {
    param(
        [object]$FirstSnapshot,
        [object]$SecondSnapshot = $null,
        [long]$InitialEpoch = 1,
        [long]$ResetEpoch = -1,
        [long]$LoadedEpoch = -1,
        [long]$FinalEpoch = -1,
        [int]$InitialPending = 0,
        [bool]$InitialReady = $true,
        [bool]$InitialUncertain = $false,
        [hashtable]$PreconditionCounts = $null,
        [string]$ResetOperation = 'document.new',
        [string]$LoadOperation = 'document.load_fixture',
        [hashtable]$WaitCounts = $null
    )
    if ($null -eq $SecondSnapshot) { $SecondSnapshot = $FirstSnapshot }
    $state = [pscustomobject]@{ Diagnostics = 0; Snapshots = 0; CurrentEpoch = $InitialEpoch; Calls = [Collections.Generic.List[object]]::new() }
    $script = {
        param([string]$Operation, [hashtable]$Arguments)
        $state.Calls.Add([pscustomobject]@{ Operation = $Operation; Arguments = $Arguments })
        switch ($Operation) {
            'diagnostics' {
                $state.Diagnostics++
                if ($state.Diagnostics -eq 1) {
                    return @{
                        document_ready = $InitialReady
                        pending_commands = $InitialPending
                        queued_commands = 0
                        document_transition_uncertain = $InitialUncertain
                        document_epoch = $state.CurrentEpoch
                    }
                }
                return @{
                    document_ready = $true
                    pending_commands = 0
                    queued_commands = 0
                    document_transition_uncertain = $false
                    document_epoch = if ($FinalEpoch -ge 0) { $FinalEpoch } else { $state.CurrentEpoch }
                }
            }
            'document.new' {
                $state.CurrentEpoch = if ($ResetEpoch -ge 0) { $ResetEpoch } else { $state.CurrentEpoch + 1 }
                return @{ document_epoch = $state.CurrentEpoch; operation = $ResetOperation }
            }
            'document.load_fixture' {
                $state.CurrentEpoch = if ($LoadedEpoch -ge 0) { $LoadedEpoch } else { $state.CurrentEpoch + 1 }
                return @{ document_epoch = $state.CurrentEpoch; operation = $LoadOperation }
            }
            'song.snapshot' {
                $state.Snapshots++
                if ($state.Snapshots -eq 1) { return $FirstSnapshot }
                return $SecondSnapshot
            }
            'wait.condition' {
                return @{
                    condition = $Arguments.condition
                    instrument_count = if ($WaitCounts) { $WaitCounts.instrument_count } elseif ($PreconditionCounts) { $PreconditionCounts.instrument_count } else { $null }
                    phrase_count = if ($WaitCounts) { $WaitCounts.phrase_count } elseif ($PreconditionCounts) { $PreconditionCounts.phrase_count } else { $null }
                }
            }
            default { throw "unexpected operation '$Operation'" }
        }
    }.GetNewClosure()
    return [pscustomobject]@{ Send = $script; State = $state }
}
function Invoke-ScenarioCase {
    param([hashtable]$Scenario, [object]$Driver, [switch]$AllowMissingArtifacts)
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('runner-scenario-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $directory | Out-Null
    try {
        $result = Invoke-AcidNativeScenario -Scenario $Scenario -SendRequest $Driver.Send -ArtifactDirectory $directory -ResetTimeoutSeconds 5 -CommandTimeoutSeconds 5
        if (-not $AllowMissingArtifacts) {
            Assert (Test-Path -LiteralPath (Join-Path $directory ($Scenario.name + '-snapshot-1.json'))) "scenario snapshot artifact 1 was not saved ($($result.status): $($result.observation.failure_reason)); epochs=$($result.observation.document_epoch_initial),$($result.observation.document_epoch_reset),$($result.observation.document_epoch_loaded)"
            Assert (Test-Path -LiteralPath (Join-Path $directory ($Scenario.name + '-snapshot-2.json'))) "scenario snapshot artifact 2 was not saved ($($result.status): $($result.observation.failure_reason))"
        }
        return $result
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}
$passScenario = @{ name = 'alpha'; fixture = 'alpha.xrns'; assertions = @(@{ path = 'instrument_count'; expected = 1 }) }
$driver = New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot)
$result = Invoke-ScenarioCase -Scenario $passScenario -Driver $driver
Assert ($result.status -eq 'PASS' -and $result.expects -ceq 'pass') 'read-only scenario did not pass'
Assert (@($result.diff).Count -eq 0) 'passing scenario reported diffs'
Assert ($null -eq (Get-AcidScenarioReportDiff -Result $result)) 'passing scenario produced a report diff'
Assert (@($result.observation.snapshot_sha256).Count -eq 2 -and $result.observation.snapshot_sha256[0] -ceq $result.observation.snapshot_sha256[1]) 'scenario snapshot hashes were not recorded as identical'
Assert ($result.observation.document_epoch_reset -eq 2 -and $result.observation.document_epoch_loaded -eq 3 -and $result.observation.document_epoch_final -eq 3) 'scenario document epochs were not observed'
Assert ($result.observation.settled) 'scenario did not record the settled host state'
$failureDriver = New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot -InstrumentCount 2)
$failureResult = Invoke-ScenarioCase -Scenario $passScenario -Driver $failureDriver
Assert ($failureResult.status -eq 'FAIL') 'assertion mismatch did not fail the scenario'
Assert (@($failureResult.diff).Count -eq 1) 'assertion mismatch did not produce exactly one diff'
Assert ($failureResult.diff[0].path -ceq 'instrument_count' -and $failureResult.diff[0].expected -eq 1 -and $failureResult.diff[0].actual -eq 2) 'assertion diff lost expected or actual values'
$transportErrorDriver = [pscustomobject]@{
    Send = { param($Operation, $Arguments) throw 'driver transport failed' }.GetNewClosure()
}
$transportErrorResult = Invoke-ScenarioCase -Scenario $passScenario -Driver $transportErrorDriver -AllowMissingArtifacts
Assert ($transportErrorResult.status -eq 'ERROR' -and $transportErrorResult.observation.failure_reason -ceq 'scenario error: driver transport failed') 'runner transport exception was classified as an assertion failure'
$expectedFailScenario = @{
    name = 'beta'
    fixture = 'beta.xrns'
    expects = 'fail'
    assertions = @(@{ path = 'instrument_count'; expected = 1 })
    expected_diffs = @(@{ path = 'instrument_count'; expected = 1; actual = 2 })
}
$expectedFailResult = Invoke-ScenarioCase -Scenario $expectedFailScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot -InstrumentCount 2))
Assert ($expectedFailResult.status -eq 'PASS' -and $expectedFailResult.expects -ceq 'fail') 'expected-fail scenario did not verify matching diffs'
Assert ($expectedFailResult.observation.expected_diffs.Count -eq 1 -and $expectedFailResult.observation.observed_diffs.Count -eq 1 -and $expectedFailResult.observation.expected_diffs[0].actual -eq 2 -and $expectedFailResult.observation.observed_diffs[0].actual -eq 2) 'passing expected-fail scenario omitted its exact expected/observed diff record'
$expectedFailReportDiff = Get-AcidScenarioReportDiff -Result $expectedFailResult
Assert ($expectedFailReportDiff.expected.Count -eq 1 -and $expectedFailReportDiff.observed[0].actual -eq 2) 'passing expected-fail report omitted its expected diff'
$mismatchedExpectation = @{
    name = 'beta'
    fixture = 'beta.xrns'
    expects = 'fail'
    assertions = @(@{ path = 'instrument_count'; expected = 1 })
    expected_diffs = @(@{ path = 'instrument_count'; expected = 1; actual = 3 })
}
$mismatchResult = Invoke-ScenarioCase -Scenario $mismatchedExpectation -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot -InstrumentCount 2))
Assert ($mismatchResult.status -eq 'FAIL') 'expected-fail scenario accepted mismatched diffs'
Assert ($null -ne $mismatchResult.observation.expected_diffs -and $null -ne $mismatchResult.observation.observed_diffs) 'expected-fail mismatch did not record both diff sets'
$mismatchReportDiff = Get-AcidScenarioReportDiff -Result $mismatchResult
Assert ($mismatchReportDiff.expected.Count -eq 1 -and $mismatchReportDiff.observed.Count -eq 1 -and $mismatchReportDiff.expected[0].actual -eq 3 -and $mismatchReportDiff.observed[0].actual -eq 2) 'report projection dropped expected or observed assertion diffs'
$instabilityResult = Invoke-ScenarioCase -Scenario $passScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -SecondSnapshot (New-ScenarioSnapshot -InstrumentCount 2))
Assert ($instabilityResult.status -eq 'FAIL' -and $instabilityResult.observation.failure_reason -ceq 'snapshot instability') 'snapshot instability was not detected'
$unchangedScenario = @{ name = 'unchanged'; fixture = 'alpha.xrns'; unchanged = @('selected_phrase_index'); assertions = @(@{ path = 'instrument_count'; expected = 1 }) }
$unchangedResult = Invoke-ScenarioCase -Scenario $unchangedScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -SecondSnapshot (New-ScenarioSnapshot -SelectedPhrase 1))
Assert ($unchangedResult.status -eq 'FAIL' -and $unchangedResult.observation.failure_reason -ceq 'declared unchanged values changed between snapshots') 'declared unchanged path mismatch was ignored'
Assert (@($unchangedResult.diff).Count -eq 1 -and $unchangedResult.diff[0].path -ceq 'selected_phrase_index' -and $unchangedResult.diff[0].expected -eq 0 -and $unchangedResult.diff[0].actual -eq 1) 'unchanged mismatch did not report an exact diff'
$missingUnchanged = @{ name = 'missing-unchanged'; fixture = 'alpha.xrns'; unchanged = @('missing_field'); assertions = @(@{ path = 'instrument_count'; expected = 1 }) }
$missingUnchangedResult = Invoke-ScenarioCase -Scenario $missingUnchanged -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot))
Assert ($missingUnchangedResult.status -eq 'FAIL' -and $missingUnchangedResult.observation.failure_reason -ceq 'declared unchanged values changed between snapshots' -and $missingUnchangedResult.diff[0].expected -ceq '<missing>') 'missing declared unchanged path was treated as invariant'
$undoResult = Invoke-ScenarioCase -Scenario $passScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot -CanUndo $true))
Assert ($undoResult.status -eq 'FAIL' -and $undoResult.observation.failure_reason -ceq 'read-only inspection created undo history') 'undo history was not detected'
$unsettledResult = Invoke-ScenarioCase -Scenario $passScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -InitialPending 1) -AllowMissingArtifacts
Assert ($unsettledResult.status -eq 'FAIL' -and $unsettledResult.observation.failure_reason -ceq 'host not settled') 'unsettled host was not rejected'
$leakResult = Invoke-ScenarioCase -Scenario $passScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -FinalEpoch 4)
Assert ($leakResult.status -eq 'FAIL' -and $leakResult.observation.failure_reason -ceq 'diagnostics state leaked between commands') 'diagnostics state leak was not detected'
$resetMismatch = Invoke-ScenarioCase -Scenario $passScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -ResetOperation 'unexpected') -AllowMissingArtifacts
Assert ($resetMismatch.status -eq 'FAIL' -and $resetMismatch.observation.failure_reason -ceq 'new-document reset was not confirmed') 'unconfirmed reset operation was accepted'
$staleReset = Invoke-ScenarioCase -Scenario $passScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -InitialEpoch 2 -ResetEpoch 2) -AllowMissingArtifacts
Assert ($staleReset.status -eq 'FAIL' -and $staleReset.observation.failure_reason -ceq 'new-document reset was not confirmed') 'stale reset epoch was accepted'
$loadMismatch = Invoke-ScenarioCase -Scenario $passScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -LoadOperation 'unexpected') -AllowMissingArtifacts
Assert ($loadMismatch.status -eq 'FAIL' -and $loadMismatch.observation.failure_reason -ceq 'fixture load did not advance the document epoch') 'unconfirmed fixture load was accepted'
$inventoryScenario = @{ name = 'inventory'; fixture = 'alpha.xrns'; preconditions = @{ instrument_count = 1; phrase_count = 0 }; assertions = @(@{ path = 'instrument_count'; expected = 1 }) }
$inventoryMismatch = Invoke-ScenarioCase -Scenario $inventoryScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -WaitCounts @{ instrument_count = 2; phrase_count = 0 }) -AllowMissingArtifacts
Assert ($inventoryMismatch.status -eq 'FAIL' -and $inventoryMismatch.observation.failure_reason -ceq 'fixture inventory did not match its preconditions') 'mismatched inventory wait was accepted'
$malformedInventoryWait = Invoke-ScenarioCase -Scenario $inventoryScenario -Driver (New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot) -WaitCounts @{ instrument_count = '1'; phrase_count = 0 }) -AllowMissingArtifacts
Assert ($malformedInventoryWait.status -eq 'FAIL' -and $malformedInventoryWait.observation.failure_reason -ceq 'fixture inventory did not match its preconditions') 'non-numeric inventory wait response was accepted'
$emptyPreconditionScenario = @{ name = 'empty-preconditions'; fixture = 'alpha.xrns'; preconditions = @{}; assertions = @(@{ path = 'instrument_count'; expected = 0 }) }
$missingInventory = Invoke-ScenarioCase -Scenario $emptyPreconditionScenario -Driver (New-FakeScenarioDriver -FirstSnapshot @{}) -AllowMissingArtifacts
Assert ($missingInventory.status -eq 'FAIL' -and $missingInventory.observation.failure_reason -ceq 'fixture inventory snapshot has a missing or invalid instrument_count') 'missing fixture instrument count defaulted to zero'
$missingPhraseInventory = Invoke-ScenarioCase -Scenario $emptyPreconditionScenario -Driver (New-FakeScenarioDriver -FirstSnapshot @{ instrument_count = 1 }) -AllowMissingArtifacts
Assert ($missingPhraseInventory.status -eq 'FAIL' -and $missingPhraseInventory.observation.failure_reason -ceq 'fixture inventory snapshot has a missing or invalid phrase_count') 'missing fixture phrase count defaulted to zero'
$successiveDriver = New-FakeScenarioDriver -FirstSnapshot (New-ScenarioSnapshot)
$firstSuccessive = Invoke-ScenarioCase -Scenario $passScenario -Driver $successiveDriver
$secondSuccessive = Invoke-ScenarioCase -Scenario $passScenario -Driver $successiveDriver
Assert ($firstSuccessive.status -eq 'PASS' -and $secondSuccessive.status -eq 'PASS') 'successive scenarios leaked prior scenario state'
$successiveResets = @($successiveDriver.State.Calls | Where-Object Operation -eq 'document.new').Count
$successiveLoads = @($successiveDriver.State.Calls | Where-Object Operation -eq 'document.load_fixture').Count
Assert ($successiveResets -eq 2 -and $successiveLoads -eq 2) 'each scenario did not reset and reload its own fixture'
$guardListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$guardListener.Start()
$guardClient = Connect-RenoiseDriver -Session ([pscustomobject]@{Port=$guardListener.LocalEndpoint.Port}) -TimeoutSeconds 2 -ProcessCheck {}
$guardPeer = $guardListener.AcceptTcpClient()
try {
    Reject { Invoke-RenoiseDriverRequest -Client $guardClient -Session ([pscustomobject]@{Token='test'}) -Operation ping -Arguments @{} -TimeoutSeconds 2 -ProcessCheck { throw 'identity changed' } } 'identity changed'
    Assert (-not $guardPeer.GetStream().DataAvailable) 'request bytes were sent after process identity validation failed'
} finally { $guardClient.Dispose(); $guardPeer.Dispose(); $guardListener.Stop() }
$root = Join-Path ([IO.Path]::GetTempPath()) ('runner-spec-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
function Add-Trace { param($Operation,$Status,$Details) }
function Set-UserOnlyFileAcl { param($Path) }
try {
    $hashRoot = Join-Path $root 'hash-inventory'
    New-Item -ItemType Directory $hashRoot | Out-Null
    Set-Content (Join-Path $hashRoot 'file.txt') 'contents'
    $hashBeforeEmptyDirectory = Get-DirectoryHash -Path $hashRoot
    New-Item -ItemType Directory (Join-Path $hashRoot 'empty') | Out-Null
    Assert ((Get-DirectoryHash -Path $hashRoot) -cne $hashBeforeEmptyDirectory) 'directory hash ignored an added empty directory'

    if ($IsWindows) {
        $reparseRoot = Join-Path $root 'reparse-check'
        $reparseTarget = Join-Path $root 'reparse-target'
        New-Item -ItemType Directory $reparseRoot, $reparseTarget | Out-Null
        $junctionPath = Join-Path $reparseRoot 'linked'
        New-Item -ItemType Junction -Path $junctionPath -Target $reparseTarget | Out-Null
        Reject { Assert-DirectoryHasNoReparsePoints -Path $reparseRoot } 'reparse point'
        [IO.Directory]::Delete($junctionPath, $false)
    }

 foreach ($case in @('unchanged','changed','changed-empty-directory','changed-empty-fixtures','reparse','partial','failed-launch','bad-backup')) {
    $toolsPath = Join-Path $root $case
    $artifactRoot = Join-Path $toolsPath 'artifacts'
    New-Item -ItemType Directory $artifactRoot -Force | Out-Null
    $artifactId = [guid]::NewGuid().ToString('N')
    $devToolName='tool'; $sessionName='session.conf'
    $devToolPath=Join-Path $toolsPath 'source'; New-Item -ItemType Directory $devToolPath | Out-Null
    Set-Content (Join-Path $devToolPath 'main.lua') 'development'
    $sessionSourcePath=Join-Path $toolsPath 'source.conf'; Set-Content $sessionSourcePath 'token'
    $installedToolPath=Join-Path $toolsPath $devToolName; New-Item -ItemType Directory $installedToolPath | Out-Null
    Set-Content (Join-Path $installedToolPath 'main.lua') 'developer edits'
    $originalHash=Get-DirectoryHash $installedToolPath
    $sessionTargetPath=Join-Path $toolsPath $sessionName; Set-Content $sessionTargetPath 'original'
    $installedFixturesPath=Join-Path $toolsPath 'fixtures'
    $fixturesSourcePath=$null
    if ($case -eq 'changed-empty-fixtures') {
        $fixturesSourcePath=Join-Path $toolsPath 'fixture-source'; New-Item -ItemType Directory $fixturesSourcePath | Out-Null
        Set-Content (Join-Path $fixturesSourcePath 'fixture.xrns') 'development fixture'
        New-Item -ItemType Directory $installedFixturesPath | Out-Null
        Set-Content (Join-Path $installedFixturesPath 'fixture.xrns') 'original fixture'
    }
    $localBackupToolPath=$localBackupSessionPath=$null
    $localBackupFixturesPath=$null
    $toolDeployed=$sessionDeployed=$fixturesDeployed=$false
    if ($case -eq 'bad-backup') {
        function Copy-Item {
            param($LiteralPath,$Destination,[switch]$Recurse)
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse
            if ($Destination -eq (Join-Path $artifactRoot 'previous-ACID.xrnx')) { Set-Content (Join-Path $Destination 'main.lua') 'corrupted' }
        }
        try { . ([scriptblock]::Create((Get-RenoiseDeploymentOperation))); throw 'expected backup rejection' }
        catch { if ($_.Exception.Message -notmatch 'backup copy did not verify') { throw } }
        finally { Remove-Item Function:Copy-Item }
        Assert ((Get-DirectoryHash $installedToolPath) -eq $originalHash) 'bad backup changed original installation'
        continue
    }
    if ($case -eq 'partial') {
        function Move-Item { param($LiteralPath,$Destination) if ($Destination -eq $sessionTargetPath) { throw 'injected deployment failure' }; Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination }
        try { . ([scriptblock]::Create((Get-RenoiseDeploymentOperation))); throw 'expected failure' } catch { if ($_.Exception.Message -notmatch 'injected') { throw } }
        Remove-Item Function:Move-Item
    } else { . ([scriptblock]::Create((Get-RenoiseDeploymentOperation))) }
    if ($case -eq 'failed-launch') {
        try { throw 'injected launch failure' }
        catch { . ([scriptblock]::Create((Get-RenoiseRestorationOperation))) }
        Assert ((Get-DirectoryHash $installedToolPath) -eq $originalHash) 'failed launch lost original'
        continue
    }
    Assert ((Get-DirectoryHash $backupToolPath) -eq $originalHash) 'backup not verified'
    if ($case -eq 'reparse') {
        $reparseTarget = Join-Path $toolsPath 'external-target'
        New-Item -ItemType Directory $reparseTarget | Out-Null
        Set-Content -LiteralPath (Join-Path $reparseTarget 'preserve.txt') 'external data'
        $junctionPath = Join-Path $installedToolPath 'linked'
        New-Item -ItemType Junction -Path $junctionPath -Target $reparseTarget | Out-Null
        try {
            Reject { . ([scriptblock]::Create((Get-RenoiseRestorationOperation))) } 'reparse point'
            Assert (Test-Path -LiteralPath $junctionPath) 'restoration removed the deployed junction'
            Assert (Test-Path -LiteralPath $localBackupToolPath -PathType Container) 'reparse-point rejection lost the restoration backup'
            Assert ((Get-Content -LiteralPath (Join-Path $reparseTarget 'preserve.txt')) -ceq 'external data') 'restoration changed the junction target'
        } finally {
            [IO.Directory]::Delete($junctionPath, $false)
        }
    } elseif ($case -eq 'changed-empty-fixtures') {
        $addedEmptyFixtureDirectory = Join-Path $installedFixturesPath 'empty-added-during-run'
        New-Item -ItemType Directory $addedEmptyFixtureDirectory | Out-Null
        Reject { . ([scriptblock]::Create((Get-RenoiseRestorationOperation))) } 'Installed ACID fixtures changed'
        Assert (Test-Path -LiteralPath $addedEmptyFixtureDirectory -PathType Container) 'restoration removed an added empty fixture directory'
        Assert (Test-Path -LiteralPath $localBackupFixturesPath -PathType Container) 'changed fixtures lost their restoration backup'
    } elseif ($case -in @('changed','changed-empty-directory')) {
        if ($case -eq 'changed') {
            Set-Content (Join-Path $installedToolPath 'main.lua') 'changed during run'
        } else {
            New-Item -ItemType Directory (Join-Path $installedToolPath 'empty-added-during-run') | Out-Null
        }
        Reject { . ([scriptblock]::Create((Get-RenoiseRestorationOperation))) } 'changed during'
        Assert (Test-Path $localBackupToolPath) 'changed installation lost backup'
        if ($case -eq 'changed-empty-directory') {
            Assert (Test-Path (Join-Path $installedToolPath 'empty-added-during-run') -PathType Container) 'restoration removed an added empty directory'
        }
    } else {
        . ([scriptblock]::Create((Get-RenoiseRestorationOperation)))
        Assert ((Get-DirectoryHash $installedToolPath) -eq $originalHash) "restoration failed: $case"
        Assert ((Get-Content $sessionTargetPath) -eq 'original') 'sidecar restoration failed'
    }
 }
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
# Exercise the real script's missing-mapping failure and report path without starting Renoise.
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$invocation = & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/run_interactive_tests.ps1') -Suite Keyboard -ApproveDisposableSong 2>&1
Assert ($LASTEXITCODE -ne 0) 'keyboard run without a mapping returned success'
$reportLine = @($invocation | ForEach-Object { [string]$_ } | Where-Object { $_ -like 'Run report: *' })
Assert ($reportLine.Count -eq 1) 'runner failed to emit a report'
$runReport = Get-Content -LiteralPath $reportLine[0].Substring(12) -Raw | ConvertFrom-Json
Assert ($runReport.status -eq 'ERROR' -and $runReport.error -match 'TestEnvironment.Keyboard.ShowShortcut') 'missing shortcut did not fail clearly'
Assert ($runReport.keyboard.negative_cases[0].name -eq 'missing_mapping' -and $runReport.keyboard.negative_cases[0].input_sent -eq $false) 'missing mapping guard did not report a no-input negative case'
Write-Output 'PASS runner transport, ownership, keyboard configuration and installation lifecycle'
