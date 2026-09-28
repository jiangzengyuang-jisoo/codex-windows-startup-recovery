# PowerShell 7 entry point. Do not run from a Codex task.
# One bounded launch/recovery attempt; never installs a service or scheduled task.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$title = 'Codex 启动准备'
$form = $null
$messageLabel = $null
$cancelButton = $null
$mainHandle = $null
$backendHandle = $null
$replacementHandle = $null
$mutex = $null
$lockOwned = $false
$script:cancelled = $false
$script:closingNormally = $false
$script:terminationAttempted = $false
$state = [ordered]@{ StartedUtc=[datetime]::UtcNow.ToString('o'); Result='starting'; DesktopPid=$null; OriginalBackendPid=$null; ReplacementBackendPid=$null; StopAttempts=0; Detail='' }

function Read-ProcessSnapshot {
    @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 |
        Select-Object ProcessId, ParentProcessId, SessionId, Name, ExecutablePath, CommandLine, CreationDate)
}
function Pump-Wait {
    param([int]$Milliseconds)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $Milliseconds) {
        [Windows.Forms.Application]::DoEvents()
        if ($script:cancelled) { throw '用户取消；不会再停止任何后台。' }
        Start-Sleep -Milliseconds 50
    }
}
function Show-Progress {
    param([string]$Text)
    if ($null -eq $form) { return }
    $messageLabel.Text=$Text
    [Windows.Forms.Application]::DoEvents()
    if ($script:cancelled) { throw '用户取消；不会再停止任何后台。' }
}
function Complete-Notice {
    param([string]$Text, [bool]$Success)
    if ($null -eq $form) { return }
    $script:closingNormally=$true
    $cancelButton.Text='关闭提示'
    $messageLabel.ForeColor = if ($Success) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }
    $messageLabel.Text=$Text + "`r`n`r`n提示将在 8 秒后自动关闭。"
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 8 -and -not $form.IsDisposed) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . (Join-Path $PSScriptRoot 'Launcher.Core.ps1')
    Add-Type -Path (Join-Path $PSScriptRoot 'WindowsActivation.cs')
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=[Threading.Mutex]::new($false, ('Local\Codex.StartAndRecover.'+$sid+'.v1'))
    try { $lockOwned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockOwned=$true }
    if (-not $lockOwned) {
        [CodexStartupRecovery.Native]::FocusProgress($title)
        return
    }
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=[Windows.Forms.Form]::new()
    $form.Text=$title
    $form.ClientSize=[Drawing.Size]::new(560,205)
    $form.FormBorderStyle=[Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition=[Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox=$false
    $form.MinimizeBox=$false
    $form.TopMost=$true
    $form.Font=[Drawing.Font]::new('Microsoft YaHei UI',10)
    $messageLabel=[Windows.Forms.Label]::new()
    $messageLabel.Location=[Drawing.Point]::new(22,20)
    $messageLabel.Size=[Drawing.Size]::new(516,124)
    $messageLabel.Text="正在检查已有窗口。`r`n准备期间请勿在 Codex 中发送任务。"
    $form.Controls.Add($messageLabel)
    $cancelButton=[Windows.Forms.Button]::new()
    $cancelButton.Text='取消恢复'
    $cancelButton.Location=[Drawing.Point]::new(408,156)
    $cancelButton.Size=[Drawing.Size]::new(130,32)
    $cancelButton.Add_Click({ if ($script:closingNormally) { $form.Close() } else { $script:cancelled=$true } })
    $form.Controls.Add($cancelButton)
    $form.Add_FormClosing({ if (-not $script:closingNormally) { $_.Cancel=$true; $script:cancelled=$true } })
    $form.Show()
    [Windows.Forms.Application]::DoEvents()

    $family='OpenAI.Codex_2p2nqsd0c76g0'
    $appId=$family+'!App'
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    $packages=@(Get-AppxPackage -Name OpenAI.Codex | Where-Object PackageFamilyName -eq $family)
    if ($packages.Count -ne 1) { throw '未找到唯一的正式版 Codex 注册包。没有启动或恢复应用。' }
    $package=$packages[0]
    $desktopPath=Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    $bundledPath=Join-Path $package.InstallLocation 'app\resources\codex.exe'
    $runtimeRoot=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $before=@(Read-ProcessSnapshot)
    $existing=@(Get-DesktopCandidates $before $session)
    if ($existing.Count -gt 0) {
        # Terminal branch: existing desktop instances can never reach TerminateOnce.
        Show-Progress '检测到 Codex 已在运行，正在打开窗口。不会停止任何后台。'
        $null=[CodexStartupRecovery.Native]::Activate($appId)
        $state.Result='opened-existing'
        Complete-Notice "已打开原有 Codex。`r`n未执行后台恢复，也不会随后停止任何进程。`r`n若原窗口仍转圈，请先正常退出，再使用此入口。" $true
        return
    }

    [xml]$manifest=Get-Content -LiteralPath (Join-Path $package.InstallLocation 'AppxManifest.xml') -Raw
    $entry=@($manifest.Package.Applications.Application | Where-Object Id -eq 'App')
    if ($entry.Count -ne 1 -or $entry[0].Executable.Replace('/','\') -ine 'app\ChatGPT.exe') {
        throw '应用入口与已审核版本不一致；停止，不尝试其他启动方式。'
    }
    $bundledHash=(Get-FileHash -LiteralPath $bundledPath -Algorithm SHA256).Hash
    # Final preactivation snapshot closes the time spent checking package files.
    $before=@(Read-ProcessSnapshot)
    if (@(Get-DesktopCandidates $before $session).Count -gt 0) {
        $null=[CodexStartupRecovery.Native]::Activate($appId)
        $state.Result='opened-existing-race'
        Complete-Notice '检测到其他入口已经启动 Codex。已打开窗口，不执行恢复。' $true
        return
    }
    Show-Progress "正在启动新的 Codex 实例。`r`n即使主窗口先出现，也请勿发送任务；请等本提示宣布结束。"
    $activationUtc=[datetime]::UtcNow
    $activationClock=[Diagnostics.Stopwatch]::StartNew()
    $activatedId=[CodexStartupRecovery.Native]::Activate($appId)
    $snapshot=@(Read-ProcessSnapshot)
    $desktop=@($snapshot | Where-Object ProcessId -eq $activatedId)
    if ($desktop.Count -ne 1) { throw '找不到 Windows 激活返回的桌面进程；不恢复。' }
    $desktop=$desktop[0]
    Assert-NewDesktop $desktop $activatedId $activationUtc $desktopPath $session $before
    $mainHandle=[CodexStartupRecovery.BoundProcess]::new($activatedId,$desktopPath,$desktop.CreationDate.ToUniversalTime().Ticks,$false)
    $mainHandle.AssertPackageFamily($family)
    $state.DesktopPid=$activatedId

    $backend=$null
    while ($activationClock.Elapsed.TotalSeconds -lt 30) {
        $snapshot=@(Read-ProcessSnapshot)
        $mains=@(Get-DesktopCandidates $snapshot $session)
        if ($mains.Count -ne 1 -or -not (Test-SameProcess $desktop $mains[0]) -or -not $mainHandle.IsAlive) {
            throw '新桌面已经退出或身份变化；不会停止后台。'
        }
        $children=@(Get-OwnedBackends $snapshot $desktop $runtimeRoot $bundledPath)
        if ($children.Count -gt 1) { throw '发现多个 app-server，不进行恢复。' }
        if ($children.Count -eq 1) { $backend=$children[0]; break }
        Pump-Wait 200
    }
    if ($null -eq $backend) { throw '30 秒内未找到唯一的新后台；已停止，不重试。' }
    Assert-RecoveryTarget $snapshot $desktop $backend $before $runtimeRoot $bundledPath
    $backendHandle=[CodexStartupRecovery.BoundProcess]::new($backend.ProcessId,$backend.ExecutablePath,$backend.CreationDate.ToUniversalTime().Ticks,$true)
    if ((Get-FileHash -LiteralPath $backendHandle.ImagePath -Algorithm SHA256).Hash -ne $bundledHash) {
        throw '后台文件与本次安装包不一致；不恢复。'
    }
    $state.OriginalBackendPid=$backend.ProcessId
    $backendSettleClock=[Diagnostics.Stopwatch]::StartNew()
    # Give the renderer time to attach its startup listeners. This is one attempt,
    # not a spinner detector: current builds can keep their logs buffered.
    while ($activationClock.Elapsed.TotalSeconds -lt 35 -or $backendSettleClock.Elapsed.TotalSeconds -lt 3) {
        Show-Progress "正在等待初始化（启动后至少 35 秒），再执行一次恢复。`r`n请勿发送任务；不会处理其他桌面实例。"
        Pump-Wait 250
        $snapshot=@(Read-ProcessSnapshot)
        Assert-RecoveryTarget $snapshot $desktop $backend $before $runtimeRoot $bundledPath
        if (-not $mainHandle.IsAlive -or -not $backendHandle.IsAlive) { throw '原进程已退出，不执行恢复。' }
    }
    Show-Progress "正在执行一次后台恢复。`r`n请稍候，新后台稳定后会明确提示。"
    $snapshot=@(Read-ProcessSnapshot)
    Assert-RecoveryTarget $snapshot $desktop $backend $before $runtimeRoot $bundledPath
    $renderers=@($snapshot | Where-Object {
        $_.Name -ieq 'ChatGPT.exe' -and $_.ParentProcessId -eq $desktop.ProcessId -and
        $_.SessionId -eq $session -and $_.ExecutablePath -ieq $desktopPath -and
        $_.CommandLine -match '(?:^|\s)--type=renderer(?:\s|$)'
    })
    if ($renderers.Count -eq 0) { throw '尚未确认本次桌面的页面进程；不执行后台恢复。' }
    if (-not $mainHandle.IsAlive -or -not $backendHandle.IsAlive) { throw '原进程已退出，不执行恢复。' }
    if ($script:cancelled -or $script:terminationAttempted) { throw '恢复已取消或已尝试；不会重复执行。' }
    $script:terminationAttempted=$true
    $state.StopAttempts=1
    $stopUtc=[datetime]::UtcNow
    $backendHandle.TerminateOnce()

    $replacement=$null
    $waitClock=[Diagnostics.Stopwatch]::StartNew()
    while ($waitClock.Elapsed.TotalSeconds -lt 30) {
        Pump-Wait 300
        $snapshot=@(Read-ProcessSnapshot)
        $mains=@(Get-DesktopCandidates $snapshot $session)
        if ($mains.Count -ne 1 -or -not (Test-SameProcess $desktop $mains[0]) -or -not $mainHandle.IsAlive) {
            throw '桌面在恢复后退出或身份变化；不会执行第二次停止。'
        }
        $children=@(Get-OwnedBackends $snapshot $desktop $runtimeRoot $bundledPath)
        if ($children.Count -gt 1) { throw '恢复后后台不唯一；不再操作。' }
        if ($children.Count -eq 1 -and -not (Test-SameProcess $backend $children[0])) {
            if ($children[0].CreationDate.ToUniversalTime() -lt $stopUtc) { throw '替换后台启动时间异常；不再操作。' }
            $replacement=$children[0]; break
        }
    }
    if ($null -eq $replacement) { throw '已执行一次恢复，但 30 秒内未确认替换后台；不再重试。' }
    $replacementHandle=[CodexStartupRecovery.BoundProcess]::new($replacement.ProcessId,$replacement.ExecutablePath,$replacement.CreationDate.ToUniversalTime().Ticks,$false)
    $state.ReplacementBackendPid=$replacement.ProcessId
    Show-Progress "已发现替换后台，正在观察 5 秒。`r`n停止操作已结束，不会再停止任何进程。"
    $stable=[Diagnostics.Stopwatch]::StartNew()
    while ($stable.Elapsed.TotalSeconds -lt 5) {
        Pump-Wait 300
        $snapshot=@(Read-ProcessSnapshot)
        Assert-RecoveryTarget $snapshot $desktop $replacement $before $runtimeRoot $bundledPath
        if (-not $mainHandle.IsAlive -or -not $replacementHandle.IsAlive) { throw '替换后台未稳定；不再重试。' }
    }
    $state.Result='backend-replaced-ui-unverified'
    Complete-Notice "后台恢复步骤已完成。不会再停止任何进程。`r`n已确认替换后台稳定存在；尚未验证界面加载。`r`n请等 Codex 界面可用后再发送任务。" $true
} catch {
    $state.Result=if ($script:terminationAttempted) { 'stopped-once-needs-check' } else { 'aborted-without-stop' }
    $state.Detail=$_.Exception.Message
    $notice=$_.Exception.Message + "`r`n不会继续重试，也不会扩大进程匹配范围。"
    if ($null -ne $form -and -not $form.IsDisposed) { Complete-Notice $notice $false }
    else {
        try { $null=[Windows.Forms.MessageBox]::Show($notice,'Codex 启动未完成',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) } catch { Write-Error $notice }
    }
} finally {
    if ($lockOwned) {
        $state.FinishedUtc=[datetime]::UtcNow.ToString('o')
        try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-run.json') -Encoding UTF8 } catch { }
    }
    if ($null -ne $replacementHandle) { $replacementHandle.Dispose() }
    if ($null -ne $backendHandle) { $backendHandle.Dispose() }
    if ($null -ne $mainHandle) { $mainHandle.Dispose() }
    $script:closingNormally=$true
    if ($null -ne $form) { $form.Dispose() }
    if ($lockOwned) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
