<#
ParseSave.ps1 - read Thumper's progress file: levels, scores, ranks per section.

The save is not encrypted. It is a stream of length-prefixed ASCII strings (int32 length
followed by the bytes) interleaved with int32 values, with some single-byte fields that
break 4-byte alignment - so this scans for the known string tokens rather than assuming a
fixed record layout.

Layout as observed: a "levelN" token, then that level's overall RANK_* and total score,
then a run of per-section RANK_* entries each followed by a cumulative int32 score.

Verified against the in-game level select screen: level1 reads 115250 / RANK_A with
sections S A A A S S A B S S C S C C, which is exactly what the screen displays.

Usage:
  .\ParseSave.ps1                 # auto-detect the save under the game dir
  .\ParseSave.ps1 -Level level1   # just one level
  .\ParseSave.ps1 -Json           # machine-readable, for the narrator
#>
param(
    [string]$Path = "",
    [string]$Level = "",
    [switch]$Json
)

if (-not $Path) {
    $base = "C:\Program Files (x86)\Steam\steamapps\common\Thumper\savedata"
    $dir = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dir) { Write-Error "No savedata folder found under $base"; exit 1 }
    $Path = Join-Path $dir.FullName "data_0.sav"
}
if (-not (Test-Path $Path)) { Write-Error "Save file not found: $Path"; exit 1 }

$b = [System.IO.File]::ReadAllBytes($Path)

# Collect every length-prefixed ASCII token and remember where it sat, so we can read the
# int32 that follows a rank token and group ranks under the preceding level token.
$tokens = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt ($b.Length - 8); $i++) {
    $len = [BitConverter]::ToInt32($b, $i)
    if ($len -lt 4 -or $len -gt 16) { continue }
    if (($i + 4 + $len) -gt $b.Length) { continue }
    $ok = $true
    for ($k = 0; $k -lt $len; $k++) {
        $c = $b[$i + 4 + $k]
        if ($c -lt 0x30 -or $c -gt 0x7A) { $ok = $false; break }
    }
    if (-not $ok) { continue }
    $s = [System.Text.Encoding]::ASCII.GetString($b, $i + 4, $len)
    if ($s -match '^(level\d+|RANK_[SABCD]|RANK_NONE)$') {
        [void]$tokens.Add([pscustomobject]@{ Text = $s; At = $i; After = $i + 4 + $len })
        $i = $i + 3 + $len
    }
}

$levels = New-Object System.Collections.ArrayList
$cur = $null
foreach ($t in $tokens) {
    if ($t.Text -like 'level*') {
        $cur = [pscustomobject]@{
            Name     = $t.Text
            Rank     = ''
            Score    = 0
            Sections = New-Object System.Collections.ArrayList
        }
        [void]$levels.Add($cur)
        continue
    }
    if (-not $cur) { continue }

    $rank = $t.Text -replace '^RANK_', ''
    $score = 0
    if (($t.After + 4) -le $b.Length) { $score = [BitConverter]::ToInt32($b, $t.After) }

    # The first rank after a level token is that level's overall rank + total score;
    # everything after it is a per-section entry.
    if (-not $cur.Rank) {
        $cur.Rank = $rank
        $cur.Score = $score
    } else {
        [void]$cur.Sections.Add($rank)
    }
}

# The overall rank is written twice in a row; drop the duplicate that lands in Sections.
foreach ($lv in $levels) {
    if ($lv.Sections.Count -gt 0 -and $lv.Sections[0] -eq $lv.Rank) { $lv.Sections.RemoveAt(0) }
}

# Each level stores its section ranks TWICE - once for normal play and once for PLAY+ -
# preceded by two RANK_NONE placeholders. Verified against the level select screen:
# level1 -> 15 sections (14 played) and level2 -> 22 (20 played), which is exactly the
# number of rank boxes the game draws. So the real section count is (tokens - 2) / 2.
$parsed = New-Object System.Collections.ArrayList
foreach ($lv in $levels) {
    $all = @($lv.Sections)
    if ($all.Count -lt 4) { continue }   # trailing stub entries, not real levels
    $n = [int](($all.Count - 2) / 2)
    if ($n -lt 1) { continue }
    # Block 1 is the CURRENT RUN through the level (this is what the level select screen
    # draws); block 2 is the all-time best per section. Confirmed by restarting level 1:
    # block 1 reset to a single "B" while the level's best score and rank were untouched.
    $normal = $all[2..(1 + $n)]
    $plus = if (($all.Count) -ge (2 + 2 * $n)) { $all[(2 + $n)..(1 + 2 * $n)] } else { @() }
    [void]$parsed.Add([pscustomobject]@{
        Name     = $lv.Name
        Rank     = $lv.Rank
        Score    = $lv.Score
        Sections = $normal
        Plus     = $plus
    })
}
$levels = $parsed

if ($Level) { $levels = @($levels | Where-Object { $_.Name -eq $Level }) }

if ($Json) {
    $levels | ForEach-Object {
        [pscustomobject]@{
            name     = $_.Name
            rank     = $_.Rank
            score    = $_.Score
            sections = @($_.Sections)   # current run
            best     = @($_.Plus)       # all-time best per section
        }
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}

Write-Output ("save: {0}" -f $Path)
Write-Output ("levels found: {0}" -f $levels.Count)
foreach ($lv in $levels) {
    $played = @($lv.Sections | Where-Object { $_ -ne 'NONE' }).Count
    $sRanks = @($lv.Sections | Where-Object { $_ -eq 'S' }).Count
    Write-Output ""
    Write-Output ("{0}: score {1:N0}, rank {2}" -f $lv.Name, $lv.Score, $lv.Rank)
    Write-Output ("  sections: {0} total, {1} played, {2} S ranks" -f $lv.Sections.Count, $played, $sRanks)
    Write-Output ("  ranks: {0}" -f (($lv.Sections) -join ' '))
    $pPlayed = @($lv.Plus | Where-Object { $_ -ne 'NONE' }).Count
    if ($pPlayed -gt 0) { Write-Output ("  play+:  {0} played" -f $pPlayed) }
}

