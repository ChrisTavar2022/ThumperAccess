# LevelData.ps1 - level progress read from Thumper's save file rather than the screen: the
# level select summary, the checkpoint screen's per-section results, and the rank letter
# spoken when a section is finished. Dot-sourced by ThumperNarrator.ps1, which defines
# $RepoRoot.

# The level select screen draws the score and a grid of tiny rank letters. Those same
# values sit in the save file as plain text, verified character-for-character against the
# screen, so read them from there: it is exact, and it also covers sections that are too
# small to OCR reliably.
$saveParser = Join-Path $RepoRoot "tools\savedata\ParseSave.ps1"
$script:LevelData = $null
$script:SaveStamp = $null
$script:SavePath = $null
$script:InstallDirWarned = $false

# Thumper's install folder was assumed to be under the default Steam library
# (C:\...\Steam\steamapps\common\Thumper), but every player's machine is different: Steam
# can have several libraries across drives, or Thumper might not be under Steam's default
# library at all, and a missing path fails silent (Get-ChildItem on a missing path just
# returns nothing, no error) - the level summary just quietly never speaks. Three ways to
# find it, in order: a player-set override, every Steam library the local client knows
# about, then the single-library default as a last resort.
function Find-ThumperInstallDir {
    $configPath = Join-Path $RepoRoot "config\game-dir.txt"
    if (Test-Path $configPath) {
        $override = Get-Content $configPath -ErrorAction SilentlyContinue |
            Where-Object { $_ -and ($_.Trim() -notlike '#*') } | Select-Object -First 1
        if ($override -and (Test-Path $override.Trim())) { return $override.Trim() }
    }

    $roots = @("C:\Program Files (x86)\Steam")
    $vdf = "C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        $found = [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
        if ($found) { $roots = $found }
    }
    foreach ($r in $roots) {
        $candidate = Join-Path $r "steamapps\common\Thumper"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Update-LevelData {
    try {
        if (-not $script:SavePath) {
            $installDir = Find-ThumperInstallDir
            if (-not $installDir) {
                # A silent failure here is invisible to a blind player - the level select
                # screen would just never announce its summary, with nothing on screen to
                # explain why. Say it once (not every poll) so it is actually discoverable.
                if (-not $script:InstallDirWarned) {
                    $script:InstallDirWarned = $true
                    $msg = "Could not find the Thumper install folder. Level summaries " +
                           "are unavailable until you set it in config game-dir.txt. See INSTALL.md."
                    Write-Host $msg
                    Say $msg
                }
                return
            }
            $base = Join-Path $installDir "savedata"
            $d = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $d) { return }
            $script:SavePath = $d.FullName
        }
        # Thumper alternates between two save slots, data_0.sav and data_1.sav, on every
        # save - always reading data_0 left this one save behind about half the time. The
        # newest slot is the current one.
        $file = Get-ChildItem $script:SavePath -Filter 'data_*.sav' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if (-not $file) { return }
        # Re-read only when the game has actually saved, so finishing a level refreshes ranks.
        $stamp = "{0}|{1}" -f $file.Name, $file.LastWriteTimeUtc.Ticks
        if ($script:SaveStamp -eq $stamp -and $script:LevelData) { return }
        $json = & $saveParser -Json -Path $file.FullName 2>$null
        if (-not $json) { return }   # caught mid-write: leave the stamp, retry next time
        $script:SaveStamp = $stamp
        $old = $script:LevelData
        # Two steps on purpose: Windows PowerShell's ConvertFrom-Json emits a JSON array as
        # ONE object, so @($json | ConvertFrom-Json) wraps the whole array as a single item
        # and every level's sections then get merged into one 220-long list.
        $parsed = $json | ConvertFrom-Json
        $script:LevelData = @($parsed)
        if ($old) { Announce-SectionResults $old $script:LevelData }
    } catch {
        Write-Host "save read failed: $($_.Exception.Message)"
    }
}

# --- section results, announced straight from the save file ---
# Thumper saves after every finished section (confirmed 2026-09-28: consecutive slot writes
# 18 seconds apart, one more section filled in each time), so a changed save file IS the
# results screen, as exact data and with no OCR. Compare the current run's sections before
# and after: a section that is now played and differs in rank OR cumulative score was just
# finished. Comparing the score as well catches replaying a section (restart from
# checkpoint) and getting the same rank again. A restart that clears sections back to NONE
# is not announced - nothing was just finished.
#
# Only the rank letter is spoken ("S"), nothing else - a product decision (user,
# 2026-09-28): this plays mid-gameplay in a rhythm game, where the next obstacle can arrive
# at any moment, so anything longer competes with the music and the player's attention.
# Points, totals, "level complete" and new bests are left to the level select summary,
# which is heard outside gameplay. If several sections changed in one save (rare), only the
# furthest one is spoken - that is the section just finished.
function Announce-SectionResults($old, $new) {
    $rank = $null
    foreach ($lv in $new) {
        $prev = $old | Where-Object { $_.name -eq $lv.name } | Select-Object -First 1
        if (-not $prev) { continue }
        $ranks = @($lv.sections); $scores = @($lv.scores)
        $pRanks = @($prev.sections); $pScores = @($prev.scores)
        if ($ranks.Count -ne $pRanks.Count -or $scores.Count -ne $ranks.Count) { continue }
        for ($i = 0; $i -lt $ranks.Count; $i++) {
            if ($ranks[$i] -eq 'NONE') { continue }
            if ($ranks[$i] -eq $pRanks[$i] -and $scores[$i] -eq $pScores[$i]) { continue }
            $rank = $ranks[$i]
        }
    }
    if ($rank) { Say $rank }
}

function Get-LevelInfo([int]$number) {
    Update-LevelData
    if (-not $script:LevelData) { return $null }
    return $script:LevelData | Where-Object { $_.name -eq ("level{0}" -f $number) } | Select-Object -First 1
}

function Format-LevelSummary([int]$number) {
    $lv = Get-LevelInfo $number
    if (-not $lv) { return $null }
    $sections = @($lv.sections)
    $played = @($sections | Where-Object { $_ -ne 'NONE' }).Count
    $s = @($sections | Where-Object { $_ -eq 'S' }).Count
    # Report the all-time best as well as the current run. Reporting only the current run
    # is misleading: after restarting level 1 the narrator said "not played yet" while the
    # player still held a 115,250 rank A best.
    $best = @($lv.best)
    $bestPlayed = @($best | Where-Object { $_ -ne 'NONE' }).Count
    $bestS = @($best | Where-Object { $_ -eq 'S' }).Count

    if ($bestPlayed -eq 0 -and $played -eq 0) {
        return ("Level {0}, never played, {1} sections" -f $number, $sections.Count)
    }

    # A level can have sections played but no overall rank yet (it has not been finished).
    # "rank NONE" reads badly, so say it plainly.
    $rankPart = if ($lv.rank -eq 'NONE') { "not yet ranked" } else { "rank {0}" -f $lv.rank }
    $bestPart = "Level {0}, best score {1:N0}, {2}, {3} S ranks" -f $number, $lv.score, $rankPart, $bestS
    $runPart = if ($played -eq 0) {
        "current run not started"
    } else {
        "current run {0} of {1} sections" -f $played, $sections.Count
    }
    return "$bestPart. $runPart"
}

# For the "Restart from checkpoint?" screen: the rank and points for the one section the
# highlighted checkpoint starts (checkpoint N = the start of section N - the list's top
# entry is always the first section not yet played this run). Per row, not a summary of
# every section on arrival: reading all 15 at once was too much to take in (user feedback
# 2026-09-28), and the row you are on is the one you are deciding about.
# Deliberately the CURRENT RUN ($lv.sections/$lv.scores), not the all-time best - the
# screen's own rank badges show this run, and that is what matters when picking where to
# restart from.
function Format-CheckpointSection([int]$number, [int]$section) {
    $lv = Get-LevelInfo $number
    if (-not $lv) { return $null }
    $ranks = @($lv.sections); $scores = @($lv.scores)
    $i = $section - 1
    if ($i -lt 0 -or $i -ge $ranks.Count) { return $null }
    if ($ranks[$i] -eq 'NONE') { return "not played yet" }
    if ($scores.Count -ne $ranks.Count) { return "rank {0}" -f $ranks[$i] }
    $before = if ($i -gt 0 -and $scores[$i - 1] -gt 0) { $scores[$i - 1] } else { 0 }
    return ("rank {0}, {1:N0} points" -f $ranks[$i], ($scores[$i] - $before))
}
