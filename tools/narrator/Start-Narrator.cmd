@echo off
REM Start the Thumper narrator.
REM
REM THIS IS THE ENTRY POINT. Run this, not ThumperNarrator.ps1 directly: PowerShell's
REM default execution policy blocks unsigned scripts, so running the .ps1 fails with
REM "running scripts is disabled on this system". This sets bypass for this launch only
REM and changes nothing about the machine's settings.
REM
REM It also launches 32-bit PowerShell on purpose - the NVDA controller client we ship is
REM x86, and this machine is ARM64, so the 64-bit host cannot load it.
REM
REM Stop the narrator with Ctrl+C in this window, or just close the window.

"%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ThumperNarrator.ps1" %*
