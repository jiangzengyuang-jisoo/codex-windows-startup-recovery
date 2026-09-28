# Pure selection and identity checks. No process queries or side effects.
Set-StrictMode -Version Latest

function Test-SameProcess {
    param($Expected, $Actual)
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    return ($Expected.ProcessId -eq $Actual.ProcessId -and
        $Expected.ParentProcessId -eq $Actual.ParentProcessId -and
        $Expected.SessionId -eq $Actual.SessionId -and
        $Expected.Name -ieq $Actual.Name -and
        $Expected.ExecutablePath -ieq $Actual.ExecutablePath -and
        $Expected.CommandLine -ceq $Actual.CommandLine -and
        $Expected.CreationDate.ToUniversalTime().Ticks -eq $Actual.CreationDate.ToUniversalTime().Ticks)
}

function Get-DesktopCandidates {
    param([object[]]$Snapshot, [int]$SessionId)
    foreach ($p in $Snapshot) {
        if ($p.Name -ine 'ChatGPT.exe' -or $p.SessionId -ne $SessionId) { continue }
        if (-not $p.ExecutablePath -or -not $p.CommandLine -or -not $p.CreationDate) {
            throw '无法读取 ChatGPT 进程身份，已停止操作。'
        }
        if ($p.ExecutablePath -match '\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$' -and
            $p.CommandLine -notmatch '(?:^|\s)--type=') { $p }
    }
}

function Assert-NewDesktop {
    param($Desktop, [uint32]$ActivatedId, [datetime]$ActivationUtc,
        [string]$ExpectedPath, [int]$SessionId, [object[]]$Before)
    if ($null -eq $Desktop -or $Desktop.ProcessId -ne $ActivatedId -or
        $Desktop.Name -ine 'ChatGPT.exe' -or $Desktop.ExecutablePath -ine $ExpectedPath -or
        $Desktop.SessionId -ne $SessionId -or -not $Desktop.CommandLine -or
        $Desktop.CommandLine -match '(?:^|\s)--type=' -or -not $Desktop.CreationDate -or
        $Desktop.CreationDate.ToUniversalTime() -lt $ActivationUtc) {
        throw '不能确认桌面进程由本次启动创建；不会停止后台。'
    }
    if (@($Before | Where-Object ProcessId -eq $ActivatedId).Count -ne 0) {
        throw '桌面 PID 在启动前已存在；不会停止后台。'
    }
}

function Get-OwnedBackends {
    param([object[]]$Snapshot, $Desktop, [string]$RuntimeRoot, [string]$BundledPath)
    $runtimePattern = '^' + [regex]::Escape($RuntimeRoot.TrimEnd('\')) + '\\[0-9a-f]{16}\\codex\.exe$'
    foreach ($p in $Snapshot) {
        if ($p.Name -ine 'codex.exe' -or $p.ParentProcessId -ne $Desktop.ProcessId) { continue }
        if (-not $p.ExecutablePath -or -not $p.CommandLine -or -not $p.CreationDate) {
            throw '无法读取桌面子进程身份；不会停止后台。'
        }
        if ($p.CommandLine -notmatch '(?:^|\s)app-server(?:\s|$)') { continue }
        if ($p.SessionId -ne $Desktop.SessionId -or
            $p.CreationDate.ToUniversalTime() -lt $Desktop.CreationDate.ToUniversalTime() -or
            ($p.ExecutablePath -notmatch $runtimePattern -and $p.ExecutablePath -ine $BundledPath)) {
            throw '后台路径、会话或启动时间不符合预期；不会扩大匹配范围。'
        }
        $p
    }
}

function Assert-RecoveryTarget {
    param([object[]]$Snapshot, $Desktop, $Backend, [object[]]$Before,
        [string]$RuntimeRoot, [string]$BundledPath)
    $mains = @(Get-DesktopCandidates -Snapshot $Snapshot -SessionId $Desktop.SessionId)
    if ($mains.Count -ne 1 -or -not (Test-SameProcess $Desktop $mains[0])) {
        throw '桌面身份变化或出现多个实例；停止恢复，不停止任何后台。'
    }
    $children = @(Get-OwnedBackends $Snapshot $Desktop $RuntimeRoot $BundledPath)
    if ($children.Count -ne 1 -or -not (Test-SameProcess $Backend $children[0])) {
        throw '后台身份变化、已自行重启或数量不唯一；停止恢复。'
    }
    if (@($Before | Where-Object ProcessId -eq $Backend.ProcessId).Count -ne 0) {
        throw '后台 PID 在本次启动前已存在；不会停止它。'
    }
}
