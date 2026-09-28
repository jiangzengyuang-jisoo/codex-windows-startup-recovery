# Only for a desktop stuck at startup, with no active task.
# Run from a separate PowerShell window, never from a working Codex task.
& {
    $ErrorActionPreference = 'Stop'
    $all = @(Get-CimInstance Win32_Process)

    $desktop = @($all | Where-Object {
        $_.Name -eq 'ChatGPT.exe' -and
        $_.ExecutablePath -match '\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$' -and
        $_.CommandLine -notmatch '--type='
    })

    $backend = @($all | Where-Object {
        $_.Name -eq 'codex.exe' -and
        $_.ParentProcessId -in $desktop.ProcessId -and
        $_.CommandLine -match '(?:^|\s)app-server(?:\s|$)'
    })

    if ($backend.Count -ne 1) {
        $backend | Format-List ProcessId, ParentProcessId, CommandLine
        throw 'Could not uniquely identify the desktop backend. Nothing was stopped.'
    }

    Stop-Process -Id $backend[0].ProcessId
    'Stopped only that backend. Keep the desktop window open and wait about 10 seconds.'
}
