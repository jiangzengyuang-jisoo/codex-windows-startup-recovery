# Creates a shortcut only. Does not start Codex or change execution policy.
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PowerShellPath,
    [string]$DestinationDirectory = [Environment]::GetFolderPath('DesktopDirectory')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($file in @('Start-Codex.ps1','Launcher.Core.ps1','WindowsActivation.cs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) {
        throw "Missing companion file: $file. Extract the whole repository first."
    }
}
if (-not $PowerShellPath) {
    $candidates = @(
        (Join-Path $PSHOME 'pwsh.exe')
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
    )
    $PowerShellPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $PowerShellPath -or -not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
    throw 'PowerShell 7 was not found. Supply -PowerShellPath with an existing pwsh.exe. Nothing was installed.'
}
$shellFile = Get-Item -LiteralPath $PowerShellPath
if ($shellFile.Name -ine 'pwsh.exe' -or $shellFile.VersionInfo.FileMajorPart -lt 7) {
    throw 'The target must be an existing PowerShell 7+ pwsh.exe.'
}
if (-not $DestinationDirectory -or -not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
    throw 'Shortcut destination does not exist.'
}
$destination = Join-Path $DestinationDirectory 'Codex 启动并恢复.lnk'
if (Test-Path -LiteralPath $destination) {
    throw "Refusing to overwrite an existing shortcut: $destination"
}
$entry = Join-Path $PSScriptRoot 'Start-Codex.ps1'
if ($PSCmdlet.ShouldProcess($destination, 'Create Codex launch-and-recover shortcut (do not run)')) {
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($destination)
    $shortcut.TargetPath = $shellFile.FullName
    $shortcut.Arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -File "' + $entry + '"'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Codex startup workaround: existing instance opens only; a verified new instance gets at most one recovery.'
    $shortcut.Save()
    Write-Output "Created: $destination"
    Write-Output 'Nothing was launched. Keep this extracted folder in its current location.'
}
