<#
Uninstall-AutoStart.ps1 - removes the logon task Install-AutoStart.ps1 registered. Run
this before deleting the project folder, or the task is left pointing at files that no
longer exist and will silently fail at every login from then on.
#>

$taskName = "ThumperAccessWatcher"
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "Auto-start was not installed - nothing to remove."
    exit 0
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Write-Host "Auto-start removed."
