# Updates.ps1 - the once-per-launch update check, and installing an update when the player
# presses any F key. Dot-sourced by ThumperNarrator.ps1, which defines $RepoRoot and
# $NarratorDir; state lives on $S (Announcer.ps1).

# A single check at startup, not on a timer: the narrator is typically relaunched once per
# play session anyway (more so with auto-start), so that already gives frequent-enough
# checks. A blocked or slow request just means a few seconds' delay before the main loop
# starts - Check-Update.ps1 never throws, so a failed check (no internet, GitHub down, no
# release published yet) is silently a no-op here too.
function Invoke-UpdateCheck {
    try {
        $updateJson = & (Join-Path $RepoRoot "tools\updater\Check-Update.ps1") 2>$null
        if (-not $updateJson) { return }
        $update = $updateJson | ConvertFrom-Json
        if ($update.Available) {
            $S.UpdateAvailable = $true
            $S.UpdateUrl = $update.Url
            $msg = "A new version, $($update.Version), is available. Press any F key to install it."
            Write-Host $msg
            Say $msg
        }
    } catch {
        # Same principle as everywhere else this narrator talks to the outside world (the
        # save file, the game window): a missing or broken updater must never take it down.
    }
}

# Auto-start tasks registered by v1.0.0 run "powershell.exe -WindowStyle Hidden", which
# Windows 11 ignores when Windows Terminal is the default console: a visible window at every
# login, and closing it kills auto-start (2026-09-29). Updating replaces the files but not the
# task, and the narrator cannot fix the task itself - Set-ScheduledTask is "Access is denied"
# from the narrator's own process too (tested 2026-09-29). So tell the player, at startup,
# until they re-run the installer. A player without auto-start hears nothing.
function Test-AutoStartTask {
    try {
        $task = Get-ScheduledTask -TaskName "ThumperAccessWatcher" -ErrorAction SilentlyContinue
        if (-not $task) { return }
        if ($task.Actions[0].Execute -ieq 'conhost.exe') { return }
        $msg = "Auto-start needs a one-time update. Run Install-AutoStart from the tools, setup folder again."
        Write-Host $msg
        Say $msg -Queue
    } catch {
        # Never let this check take the narrator down.
    }
}

# Any F1-F12 key installs, but only while an update is actually pending, and only while
# Thumper is in front - "press any of the top keys", not one specific key a blind player
# would need to have memorised.
function Test-UpdateHotkey {
    if (-not $S.UpdateAvailable) { return }
    $fKeyDown = $false
    for ($vk = 0x70; $vk -le 0x7B; $vk++) {
        if (([ThumperVision]::GetAsyncKeyState($vk) -band 0x8000) -ne 0) { $fKeyDown = $true; break }
    }
    $pressed = $fKeyDown -and -not $S.FKeyWas
    $S.FKeyWas = $fKeyDown
    if (-not $pressed -or -not [ThumperVision]::ThumperFocused()) { return }

    Say "Installing update. Please wait."
    try {
        & (Join-Path $RepoRoot "tools\updater\Install-Update.ps1") -Url $S.UpdateUrl
        Say "Update installed. Restarting the narrator."
        Start-Sleep -Milliseconds 1500
        # A fresh process, not a re-run of this loop: the files this process already loaded
        # may have just been overwritten on disk, and only a new process picks up the new
        # code. The new instance's own startup self-kill retires this one.
        Start-Process -FilePath (Join-Path $NarratorDir "Start-Narrator.cmd")
        exit
    } catch {
        Say "Update failed. Continuing with the current version."
        Write-Host "update failed: $($_.Exception.Message)"
        $S.UpdateAvailable = $false
    }
}
