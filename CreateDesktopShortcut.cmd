@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CreateDesktopShortcut.ps1"
if errorlevel 1 (
    echo.
    echo Failed to create the desktop shortcut.
    pause
)