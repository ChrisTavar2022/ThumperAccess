@echo off
REM One-time setup: makes the narrator start itself automatically whenever Thumper is
REM running, and stop when you close it. Run this once; you do not need to run it again.
REM
REM Run this .cmd, not the .ps1 directly - PowerShell's default execution policy blocks
REM unsigned scripts. This sets bypass for this one launch only.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AutoStart.ps1"
pause
