# Session 2026-09-28 - section results, two save slots, checkpoint screen per-row detail

## Two save slots (real bug, fixed)

Thumper keeps `data_0.sav` AND `data_1.sav` under `savedata/<steamid>/` and alternates
between them on every save; `data.index` (12 bytes, observed `0 | 12 | 1` as int32s) records
which is current. Everything read `data_0.sav` only, so level summaries and the checkpoint
screen's ranks were one save behind about half the time. Observed directly: `data_1` (newer)
had 6 sections played on level 1, `data_0` (written 18s earlier) had 5 - and the speech log
had announced "6 not played" on the checkpoint screen 14 seconds after section 6 was saved.

Fix: read whichever `data_*.sav` has the newest `LastWriteTimeUtc` (`Get-CurrentSaveFile` in
`ParseSave.ps1`; the same inline in the narrator's `Update-LevelData`). Mtime rather than
`data.index` because the index format is only known from one sample.

## The game saves after every section

Consecutive slot writes were 18 seconds apart with exactly one more section filled in. Each
per-section entry in the save is `RANK_x` followed by the run's **cumulative** score at the
end of that section (7800, 9500, 11700, ...; -1 when unplayed). So one section's own points =
this entry minus the previous one. `ParseSave.ps1 -Json` now emits these as `scores`.

The header right after a level's section list also has `RANK_NONE 6,15,6` for level 1 -
6 looks like "sections played this run", 15 the section count. Not used; noted only.

## Section results announcer

`Announce-SectionResults` diffs the previous and new parse whenever the save changes
(polled about once a second from the main loop; only re-parsed when the file actually
changed). A played section whose rank OR cumulative score changed was just finished -
comparing the score too catches replaying a section and getting the same rank. Sections
going back to NONE (a restart) are ignored. First version said `"Section 6, rank S, 6,000 points, total 27,100"` plus
"Level N complete" / "New best score". **Changed the same day at the user.s request to
speak only the rank letter (`"S"`)**: it plays mid-gameplay in a rhythm game, where
anything longer competes with the music and the next obstacle. Points and totals stay on
the level select summary. Do not add detail back here without asking.

Tested offline by diffing the two real slots, then **verified live**: sections 7-11 of
level 1 were spoken B, S, A, S, B, exactly matching the save, with one announcement per
section (so the game does not also save mid-section).

## Regression caught and fixed in the same session

`$script:LevelData = @($json | ConvertFrom-Json)` - Windows PowerShell 5.1's
`ConvertFrom-Json` emits a JSON array as ONE object, so `@(...)` wrapped the whole array as
a single element, and `Where-Object { $_.name -eq 'level1' }` then returned the entire array
via member enumeration. The checkpoint screen read out 220 "sections" (every level
concatenated). Fixed by assigning first, then `@($parsed)`. Watch for this pattern anywhere
JSON arrays are parsed in 5.1.

## Checkpoint screen: per-row detail instead of an all-at-once summary

User feedback: reading all 15 section ranks when the screen opens was too much, and the
row you are on did not say its own result. Now each row says its own section's result:
`"Level 1, checkpoint 6, rank S, 6,000 points"`, or `"checkpoint 7, not played yet"`.
**Checkpoint N = the start of section N** - the list's top entry is always the first
section not yet played this run (1-7 at the top with 6 played). The all-sections summary
(`Format-CheckpointSections`, `$script:lastCheckpointLevel`) was removed.

## Checkpoint screen: skipped rows

Two causes, both fixed:

1. **Change detection missed row changes.** The gold box never moves here - the list
   scrolls under it - and "LEVEL 1-3" vs "LEVEL 1-4" differ by one digit, below the text
   profile's change threshold. A single Up press with 2s of quiet either side was never
   announced. Fix: a 250ms heartbeat re-read on the gold path whenever nothing is pending;
   an unchanged row matches `$lastSpoken` and is not repeated.
2. **Latency.** Key-to-speech was ~1.3s (detect wait + two agreeing reads), so pressing
   again inside that window skipped the row. A verbose run showed 76/76 raw OCR reads were
   exact (`LEVEL 1-N`), so a clean `Level N, checkpoint N` read now skips the second
   confirming read (the Omega "current checkpoint" fallback still needs confirmation).
   Latency dropped to ~0.9s.

Result: 36/36 single presses at 1.3s intervals announced correctly, both directions, plus a
burst of 5 presses at 500ms that announced every row. One earlier miss happened with a press
only 300ms after the previous announcement, possibly faster than the game accepts input.

`Read-GoldRow` now also prints `[gold raw] '...'` under `-Verbose`. To capture verbose
output (the console window is not readable - GPU-composited), run
`SysWOW64 powershell -File ThumperNarrator.ps1 -Verbose *> file.txt` hidden; the output is
UTF-16.

## Repository cleanup for v1.0

- Removed three generic Unity-mod-template docs (`docs/setup-guide.md`,
  `docs/localization-guide.md`, `docs/menu-accessibility-checklist.md`) - none applied to
  this project.
- Rewrote `project_status.md` as a short current-state page; history lives in `notes/`.
- Checked: all scripts parse, no unused narrator functions or C# helpers, no Steam ID or
  personal email in tracked files.
