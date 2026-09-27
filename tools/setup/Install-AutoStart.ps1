<#
Install-AutoStart.ps1 - one-time setup: registers a logon task that watches for Thumper
and starts/stops the narrator with it automatically. Run once; it takes effect from the
next login onward (and can also start working immediately - see the message printed below).

Registers a per-user task, "Limited" run level - no administrator rights needed, and
nothing is installed outside this task entry, which Uninstall-AutoStart.ps1 removes.
#>

$watcher = Join-Path $PSScriptRoot "..\narrator\Watch-Thumper.ps1"
$watcher = (Resolve-Path $watcher).Path
$taskName = "ThumperAccessWatcher"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# Re-running this script (e.g. after moving the project folder) should replace the old
# registration, not fail alongside a stale one pointing at the wrong path.
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description `
    "Starts the Thumper accessibility narrator whenever Thumper is running." | Out-Null

Write-Host "Auto-start installed. From your next login, the narrator will start on its own"
Write-Host "whenever Thumper is running, and stop when you close the game."
Write-Host ""
Write-Host "Starting the watcher now as well, so it works this session too, without waiting"
Write-Host "for a fresh login:"
Start-ScheduledTask -TaskName $taskName
Write-Host "Done."
