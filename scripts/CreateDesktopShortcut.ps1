#Requires -Version 5.1

$launcherPath = Join-Path $PSScriptRoot 'DSHLauncher.ps1'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath 'DSH Launcher.lnk'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path $launcherPath)) {
    throw "DSHLauncher.ps1 was not found in $PSScriptRoot"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Start DeepSeek Harness'
$shortcut.IconLocation = "$powershellPath,0"
$shortcut.Save()

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    "Desktop shortcut created:`r`n$shortcutPath",
    'DSH Launcher',
    'OK',
    'Information'
) | Out-Null