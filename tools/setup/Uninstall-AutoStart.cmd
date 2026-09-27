@echo off
REM Removes the auto-start set up by Install-AutoStart.cmd. Run this before deleting the
REM project folder if you had auto-start on.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-AutoStart.ps1"
pause
