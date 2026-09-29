<#
Watch-Thumper.ps1 - starts the narrator automatically whenever Thumper is running, and
stops it again when Thumper closes, so a blind player never has to start it by hand.

Runs continuously (registered as a logon task by tools\setup\Install-AutoStart.ps1)
rather than once, since Thumper can be launched and closed many times in a session.

DO NOT set this up by running this file directly - use tools\setup\Install-AutoStart.cmd,
which registers it correctly (execution-policy bypass, runs hidden, starts at logon).
#>
param([int]$PollMs = 2000)

$startCmd = Join-Path $PSScriptRoot "Start-Narrator.cmd"

function Get-ThumperProcess {
    Get-Process -Name "THUMPER_win8", "THUMPER_dx9" -ErrorAction SilentlyContinue | Select-Object -First 1
}

# Matched the same way ThumperNarrator.ps1 finds a prior copy of itself to replace, so this
# never starts a second narrator on top of one the player launched by hand.
function Get-NarratorProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ThumperNarrator*' } | Select-Object -First 1
}

while ($true) {
    $thumper = Get-ThumperProcess
    $narrator = Get-NarratorProcess

    if ($thumper -and -not $narrator) {
        # Headless console for the same reason as the watcher itself (see
        # Install-AutoStart.ps1): -WindowStyle Hidden is ignored when Windows Terminal is
        # the default console, and a visible narrator window can be closed by accident.
        Start-Process -FilePath "conhost.exe" -ArgumentList "--headless", "`"$startCmd`"" -WindowStyle Hidden
    } elseif (-not $thumper -and $narrator) {
        # Thumper closed - nothing left for the narrator to read, and leaving it running
        # would mean it never actually stops until the player notices and closes it by hand.
        Stop-Process -Id $narrator.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds $PollMs
}
