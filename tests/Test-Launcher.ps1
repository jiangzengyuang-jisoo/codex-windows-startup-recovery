$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$folder=Split-Path $PSScriptRoot -Parent
$entry=Join-Path $folder 'Start-Codex.ps1'
$core=Join-Path $folder 'Launcher.Core.ps1'
$results=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body) {
    & $Body
    $results.Add([pscustomobject]@{Test=$Name;Result='PASS'})
}
function Must-Throw([scriptblock]$Body) {
    $thrown=$false
    try { & $Body | Out-Null } catch { $thrown=$true }
    if(-not $thrown){throw 'Expected a safe refusal.'}
}
function Must([bool]$Condition) { if(-not $Condition){throw 'Assertion failed.'} }
function Row([int]$Id,[int]$Parent,[string]$Name,[string]$Path,[string]$Cmd,[datetime]$Started,[int]$Session=3) {
    [pscustomobject]@{ProcessId=$Id;ParentProcessId=$Parent;Name=$Name;ExecutablePath=$Path;CommandLine=$Cmd;CreationDate=$Started;SessionId=$Session}
}
foreach($file in @($entry,$core)) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ($errors|Out-String)}
    $results.Add([pscustomobject]@{Test=('PowerShell syntax: '+[IO.Path]::GetFileName($file));Result='PASS'})
}
# Dot-source ONLY pure selection functions, never the launch entry point.
. $core
$start=[datetime]::SpecifyKind([datetime]'2026-09-28T10:00:00',[DateTimeKind]::Utc)
$path='C:\Program Files\WindowsApps\OpenAI.Codex_26.924.2738.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
$root='C:\Users\Example\AppData\Local\OpenAI\Codex\bin'
$bundled='C:\Program Files\WindowsApps\OpenAI.Codex_26.924.2738.0_x64__2p2nqsd0c76g0\app\resources\codex.exe'
$exe=$root+'\faa963e871dd422c\codex.exe'
$main=Row 120 10 'ChatGPT.exe' $path ('"'+$path+'"') $start.AddSeconds(1)
$back=Row 121 120 'codex.exe' $exe ('"'+$exe+'" app-server --analytics-default-enabled') $start.AddSeconds(2)
$other=Row 122 11 'codex.exe' $exe ('"'+$exe+'" app-server') $start.AddSeconds(2)
$render=Row 123 120 'ChatGPT.exe' $path ('"'+$path+'" --type=renderer') $start.AddSeconds(2)
$base=@($main,$back,$other,$render)
Check 'Desktop selection excludes renderer' { Must (@(Get-DesktopCandidates $base 3).Count -eq 1) }
Check 'Existing main is detected regardless of its age' { Must (@(Get-DesktopCandidates @($main) 3).Count -eq 1) }
Check 'Only direct backend is selected' { $b=@(Get-OwnedBackends $base $main $root $bundled); Must ($b.Count -eq 1 -and $b[0].ProcessId -eq 121) }
Check 'Valid new activation accepted' { Assert-NewDesktop $main 120 $start $path 3 @() }
Check 'Returned old process refused' { Must-Throw { Assert-NewDesktop $main 120 $start.AddSeconds(3) $path 3 @() } }
Check 'PID existed before activation refused' { Must-Throw { Assert-NewDesktop $main 120 $start $path 3 @($main) } }
Check 'Different activation PID refused' { Must-Throw { Assert-NewDesktop $main 999 $start $path 3 @() } }
Check 'Different session refused' { Must-Throw { Assert-NewDesktop $main 120 $start $path 4 @() } }
Check 'Valid recovery target accepted' { Assert-RecoveryTarget $base $main $back @() $root $bundled }
Check 'Missing backend refused' { Must-Throw { Assert-RecoveryTarget @($main,$other) $main $back @() $root $bundled } }
Check 'Duplicate backend refused' { $duplicate=Row 129 120 'codex.exe' $exe ('"'+$exe+'" app-server') $start.AddSeconds(3); Must-Throw { Assert-RecoveryTarget @($main,$back,$duplicate) $main $back @() $root $bundled } }
Check 'Duplicate desktop refused' { $duplicate=Row 130 10 'ChatGPT.exe' $path ('"'+$path+'"') $start.AddSeconds(3); Must-Throw { Assert-RecoveryTarget @($main,$back,$duplicate) $main $back @() $root $bundled } }
Check 'PID reused with new creation time refused' { $changed=Row 121 120 'codex.exe' $exe $back.CommandLine $start.AddSeconds(4); Must-Throw { Assert-RecoveryTarget @($main,$changed) $main $back @() $root $bundled } }
Check 'Backend command changed refused' { $changed=Row 121 120 'codex.exe' $exe ($back.CommandLine+' --different') $back.CreationDate; Must-Throw { Assert-RecoveryTarget @($main,$changed) $main $back @() $root $bundled } }
Check 'Wrong parent refused' { $changed=Row 121 119 'codex.exe' $exe $back.CommandLine $back.CreationDate; Must-Throw { Assert-RecoveryTarget @($main,$changed) $main $back @() $root $bundled } }
Check 'Unapproved executable path refused' { $changed=Row 121 120 'codex.exe' 'D:\another\codex.exe' $back.CommandLine $back.CreationDate; Must-Throw { Get-OwnedBackends @($changed) $main $root $bundled } }
Check 'Backend older than desktop refused' { $changed=Row 121 120 'codex.exe' $exe $back.CommandLine $start; Must-Throw { Get-OwnedBackends @($changed) $main $root $bundled } }
Check 'Unrelated CLI backend is left alone' { Must (@(Get-OwnedBackends @($other) $main $root $bundled).Count -eq 0) }
Check 'Non app-server child is left alone' { $child=Row 125 120 'codex.exe' $exe ('"'+$exe+'" exec-server') $back.CreationDate; Must (@(Get-OwnedBackends @($child) $main $root $bundled).Count -eq 0) }
Check 'Unknown child identity refused' { $child=Row 121 120 'codex.exe' $exe '' $back.CreationDate; Must-Throw { Get-OwnedBackends @($child) $main $root $bundled } }
Check 'Unknown desktop identity refused' { $unknown=Row 120 10 'ChatGPT.exe' '' '' $main.CreationDate; Must-Throw { Get-DesktopCandidates @($unknown) 3 } }
Check 'Backend PID present in prelaunch snapshot refused' { Must-Throw { Assert-RecoveryTarget $base $main $back @($back) $root $bundled } }
Check 'Native helper compiles without invoking it' { Add-Type -Path (Join-Path $folder 'WindowsActivation.cs'); Must ($null -ne ('CodexStartupRecovery.Native' -as [type])) }
Check 'Entry has exactly one termination call site' { $source=Get-Content -LiteralPath $entry -Raw; Must ([regex]::Matches($source,'\$backendHandle\.TerminateOnce\(\)').Count -eq 1) }
Check 'Existing-instance branch returns before recovery' { $source=Get-Content -LiteralPath $entry -Raw; Must ($source -match '(?s)if \(\$existing.Count -gt 0\).*?return\s*\}') }
Check 'No scheduling, execution-policy override or debug injection' {
    $source=(Get-Content -LiteralPath $entry -Raw)+(Get-Content -LiteralPath $core -Raw)
    Must ($source -notmatch 'Register-ScheduledTask|schtasks|Set-ExecutionPolicy|ExecutionPolicy Bypass|remote-debugging-port|_debugProcess|Stop-Process')
}
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'startup-launcher-checks.json') -Encoding UTF8
Write-Output ('PASS: '+$results.Count+' checks. Launcher entry was parsed only; no activation, window operation or process termination was executed.')
