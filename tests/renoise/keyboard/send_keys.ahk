#Requires AutoHotkey v2.0
#ErrorStdOut

exitCode := Main()
ExitApp(exitCode)

Main() {
    usage := 'Usage: AutoHotkey64.exe <script-path> --pid <Renoise-PID> --keys <AHK key sequence>'
        . ' --focus-timeout <seconds>'
        . ' [--allow-activation]'
        . '`nOptions: --help, --version, --self-test <wrong-pid|focus-mismatch> [--pid <Renoise-PID>]'

    if (A_Args.Length = 1 && A_Args[1] = '--help') {
        FileAppend(usage '`n', '*')
        return 0
    }
    if (A_Args.Length = 1 && A_Args[1] = '--version') {
        FileAppend(A_AhkVersion '`n', '*')
        return 0
    }
    if (A_Args.Length >= 2 && A_Args[1] = '--self-test') {
        if (A_Args.Length = 2) {
            return RunGuardSelfTest(A_Args[2])
        }
        if (A_Args.Length = 4 && A_Args[3] = '--pid'
            && RegExMatch(A_Args[4], '^[1-9][0-9]*$')) {
            try {
                selfTestPid := Integer(A_Args[4])
            } catch Error as err {
                return ReportFailure(2, 'Self-test PID is outside the supported integer range.')
            }
            if (selfTestPid > 4294967295) {
                return ReportFailure(2, 'Self-test PID is outside the supported integer range.')
            }
            return RunGuardSelfTest(A_Args[2], selfTestPid)
        }
        return ReportFailure(2, 'Invalid arguments.`n' . usage)
    }

    if ((A_Args.Length != 6 && A_Args.Length != 7)
        || A_Args[1] != '--pid' || A_Args[3] != '--keys'
        || A_Args[5] != '--focus-timeout'
        || (A_Args.Length = 7 && A_Args[7] != '--allow-activation')) {
        return ReportFailure(2, 'Invalid arguments.`n' . usage)
    }
    allowActivation := A_Args.Length = 7

    pidText := A_Args[2]
    if !RegExMatch(pidText, '^[1-9][0-9]*$') {
        return ReportFailure(2, 'Renoise PID must be a positive decimal integer.')
    }

    try {
        targetPid := Integer(pidText)
    } catch Error as err {
        return ReportFailure(2, 'Renoise PID is outside the supported integer range.')
    }
    if (targetPid > 4294967295) {
        return ReportFailure(2, 'Renoise PID is outside the supported integer range.')
    }

    keys := A_Args[4]
    if (keys = '' || StrLen(keys) > 512) {
        return ReportFailure(2, 'Keyboard sequence must contain between 1 and 512 characters.')
    }

    timeoutText := A_Args[6]
    if !RegExMatch(timeoutText, '^[1-9][0-9]*$') {
        return ReportFailure(2, 'Focus timeout must be a positive integer from 1 to 30 seconds.')
    }
    try {
        timeoutSeconds := Integer(timeoutText)
    } catch Error as err {
        return ReportFailure(2, 'Focus timeout must be a positive integer from 1 to 30 seconds.')
    }
    if (timeoutSeconds > 30) {
        return ReportFailure(2, 'Focus timeout must be a positive integer from 1 to 30 seconds.')
    }

    result := CheckSelectedRenoisePid(targetPid)
    if (result.Code != 0) {
        return ReportFailure(result.Code, result.Message)
    }

    ; Never steal focus unless the caller explicitly opts in for a dedicated session.
    if (allowActivation) {
        result := ActivateRenoiseWindow(targetPid, timeoutSeconds)
        if (result.Code != 0) {
            return ReportFailure(result.Code, result.Message)
        }
    }

    ; Uses the same guarded dispatcher as the negative self-tests.
    result := AttemptForegroundSend(targetPid, keys)
    if (result.Code != 0) {
        return ReportFailure(result.Code, result.Message)
    }

    FileAppend('PASS sent keyboard sequence to Renoise PID ' . targetPid
        . '; activation=' . (allowActivation ? 'opted-in' : 'disabled') . '.`n', '*')
    return 0
}

ActivateRenoiseWindow(targetPid, timeoutSeconds) {
    windowFilter := 'ahk_pid ' . targetPid
    targetWindow := WinExist(windowFilter)
    if (!targetWindow) {
        return {Code: 4, Message: 'Refusing keyboard input: selected Renoise PID ' . targetPid . ' has no window.'}
    }

    try {
        WinActivate('ahk_id ' . targetWindow)
    } catch Error as err {
        return {Code: 4, Message: 'Could not activate selected Renoise PID ' . targetPid . ': ' . err.Message}
    }

    if (!WinWaitActive('ahk_pid ' . targetPid, , timeoutSeconds)) {
        foregroundPid := GetForegroundProcessId()
        return {Code: 4, Message: 'Could not activate selected Renoise PID ' . targetPid
            . ' within ' . timeoutSeconds . ' seconds; foreground PID is ' . foregroundPid . '.'}
    }

    return CheckForegroundPid(targetPid)
}

RunGuardSelfTest(testName, targetPid := 0) {
    if (testName != 'wrong-pid' && testName != 'focus-mismatch') {
        return ReportFailure(2, 'Self-test must be wrong-pid or focus-mismatch.')
    }

    expectedCode := testName = 'wrong-pid' ? 3 : 4
    helperPid := DllCall('Kernel32\GetCurrentProcessId', 'UInt')
    if (testName = 'wrong-pid') {
        ; The real dispatcher must reject a non-Renoise PID before sending.
        result := AttemptForegroundSend(helperPid, '{Esc}')
    } else {
        if (targetPid = 0 || targetPid = helperPid) {
            return ReportFailure(2, 'Focus self-test requires the selected Renoise PID.')
        }
        ; Inject a foreground mismatch at the actual last pre-send guard.
        ; No window is activated and no keyboard sequence is sent.
        result := AttemptForegroundSend(targetPid, '{Esc}', helperPid)
    }

    if (result.Code = expectedCode) {
        FileAppend('PASS self-test ' . testName . ': send dispatcher refused (code '
            . expectedCode . ') without keyboard input.`n', '*')
        return 0
    }
    return ReportFailure(6, 'FAIL self-test ' . testName . ': expected guard code ' . expectedCode
        . ', received ' . result.Code . '.')
}

AttemptForegroundSend(targetPid, keys, simulatedForegroundPid := -1) {
    result := CheckSelectedRenoisePid(targetPid)
    if (result.Code != 0) {
        return result
    }
    result := CheckForegroundPid(targetPid, simulatedForegroundPid)
    if (result.Code != 0) {
        return result
    }
    try {
        SendKeyboardSequence(keys)
    } catch Error as err {
        return {Code: 5, Message: 'AutoHotkey could not send keyboard input: ' . err.Message}
    }
    return {Code: 0, Message: ''}
}

CheckSelectedRenoisePid(targetPid) {
    if (ProcessExist(targetPid) != targetPid) {
        return {Code: 3, Message: 'Selected PID ' . targetPid . ' is not a running Renoise process.'}
    }
    try {
        processName := ProcessGetName(targetPid)
    } catch Error as err {
        return {Code: 3, Message: 'Selected PID ' . targetPid . ' is not a running Renoise process.'}
    }

    if (StrLower(processName) != 'renoise.exe') {
        return {Code: 3, Message: 'Selected PID ' . targetPid . ' is not Renoise.exe.'}
    }
    return {Code: 0, Message: ''}
}

CheckForegroundPid(targetPid, simulatedForegroundPid := -1) {
    foregroundPid := simulatedForegroundPid = -1 ? GetForegroundProcessId() : simulatedForegroundPid
    if (foregroundPid != targetPid) {
        focusError := 'Refusing keyboard input: foreground PID ' . foregroundPid
            . ' does not match selected Renoise PID ' . targetPid . '.'
        return {Code: 4, Message: focusError}
    }
    return {Code: 0, Message: ''}
}

SendKeyboardSequence(keys) {
    ; Renoise must observe modifier and key transitions on separate input ticks.
    SetKeyDelay(20, 20)
    SendEvent(keys)
}

GetForegroundProcessId() {
    foregroundWindow := DllCall('User32\GetForegroundWindow', 'Ptr')
    if (foregroundWindow = 0) {
        return 0
    }

    foregroundPid := 0
    threadId := DllCall('User32\GetWindowThreadProcessId', 'Ptr', foregroundWindow,
        'UInt*', &foregroundPid, 'UInt')
    if (threadId = 0) {
        return 0
    }
    return foregroundPid
}

ReportFailure(exitCode, message) {
    try {
        FileAppend(message '`n', '**')
    } catch Error as err {
        OutputDebug(message)
    }
    return exitCode
}
