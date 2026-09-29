<#
ThumperNarrator.ps1 - speaks Thumper's selected menu item through NVDA.

Thumper draws its UI itself (SDL2), so there is no accessibility tree to query. This
reads the screen instead: find the full-width red highlight bar (or gold outline) that
marks the current selection, OCR the text on it, and speak it when it changes.

This file is just startup and the main loop. The work is in lib\:
  ThumperVision.cs    pixel scans over a screenshot (C#, compiled at startup)
  Speech.ps1          NVDA speech and logs\speech.log
  Ocr.ps1             Windows' built-in text recognition
  ScreenReading.ps1   screenshot -> words: rows, values, sliders, counts, titles
  LevelData.ps1       level progress and section results from the save file
  Announcer.ps1       what to say and when: change detection, confirming, repeats
  Updates.ps1         update check and install

DO NOT RUN THIS DIRECTLY. Start the narrator with Start-Narrator.cmd, which is the only
entry point. It selects 32-bit PowerShell (required: the NVDA controller client is x86,
and this host is ARM64) and bypasses the execution policy for that one launch.

Stop with Ctrl+C.
#>
param(
    [int]$PollMs = 120,
    # One poll (~170ms on the dev machine) is enough for the bar to land: measured
    # 2026-09-29, the new row's text was already complete on the first poll after the move.
    # 180 cost a second poll on every row - the difference between keeping up with presses
    # half a second apart and skipping some. A new screen still waits for two agreeing reads.
    [int]$SettleMs = 100,
    [int]$Upscale = 2,
    [switch]$Quiet,      # print what it would say, don't actually speak
    [switch]$Verbose
)

# Only one narrator at a time. A second instance does not fail visibly - it just talks
# over the first one, which is worse than not starting at all.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*ThumperNarrator*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$NarratorDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$lib = Join-Path $PSScriptRoot "lib"

if (-not ("ThumperVision" -as [type])) {
    Add-Type -TypeDefinition (Get-Content (Join-Path $lib "ThumperVision.cs") -Raw) `
        -ReferencedAssemblies System.Drawing, System.Windows.Forms
}
[void][ThumperVision]::SetProcessDPIAware()

. (Join-Path $lib "Speech.ps1")
. (Join-Path $lib "Ocr.ps1")
. (Join-Path $lib "ScreenReading.ps1")
. (Join-Path $lib "LevelData.ps1")
. (Join-Path $lib "Announcer.ps1")
. (Join-Path $lib "Updates.ps1")

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
Write-Host "Thumper narrator running on $($vs.Width)x$($vs.Height). Ctrl+C to stop."
if (-not $Quiet) { Say "Thumper narrator ready" }
Invoke-UpdateCheck
Test-AutoStartTask

# Read the save once up front, so the first section finished this session has a baseline
# to be compared against (see Announce-SectionResults).
Update-LevelData
$saveCheckAt = Get-Date

while ($true) {
    $shot = $null
    try {
        # Section results: poll the save file about once a second. Cheap - it is only
        # re-parsed when the game has actually written a new save.
        if (((Get-Date) - $saveCheckAt).TotalMilliseconds -ge 1000) {
            $saveCheckAt = Get-Date
            Update-LevelData
        }
        $shot = [ThumperVision]::Grab($vs.X, $vs.Y, $vs.Width, $vs.Height)

        # Which selection widget is on screen decides everything below. Both are checked on
        # every poll: the "Restart from checkpoint?" screen has a real gold-outlined,
        # navigable checkpoint list AND a static red "RESTART" confirm bar at the same time -
        # the only screen that does - and with gold only checked when no bar was found, the
        # navigable list was never looked at. A gold box only ever appears there or on
        # Leaderboards, so preferring it whenever found is safe everywhere else.
        $bar = [ThumperVision]::FindBar($shot)
        $gold = [ThumperVision]::FindGoldBox($shot)

        Update-LevelTitle $shot $bar $gold
        Test-UpdateHotkey

        if ($gold[0] -ge 0) {
            Invoke-GoldPoll $shot $gold
        } elseif ($bar[0] -ge 0) {
            Invoke-BarPoll $shot $bar
        } else {
            Reset-Selection
        }
    } catch {
        Write-Host "poll error: $($_.Exception.Message)"
    } finally {
        if ($shot) { $shot.Dispose() }
    }
    Start-Sleep -Milliseconds $PollMs
}
