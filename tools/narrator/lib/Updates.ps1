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
