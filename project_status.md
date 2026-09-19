# Project Status - Thumper Accessibility Mod

## Setup Info

- **Game:** Thumper (Drool LLC)
- **Install path:** `C:\Program Files (x86)\Steam\steamapps\common\Thumper`
- **Engine:** Custom native C/C++ (SDL2 + FMOD) - NOT Unity/Unreal
- **Architecture:** Thumper's exes are x64 (`THUMPER_win8.exe`, `THUMPER_dx9.exe`), but the
  **dev machine's Windows install is ARM64** (Windows on ARM), not x64. Thumper therefore
  runs under Windows' built-in x64 emulation. This matters for the hook DLL: it must be
  built as x64 (to match the process we inject into), using either the native
  ARM64-hosted cross compiler or the classic (emulated) x64-hosted compiler - both are
  installed. x64dbg attaching to Thumper will also be debugging an emulated x64 process;
  if hardware breakpoints behave oddly under emulation, that's the likely cause.
- **User experience level:** Some programming experience, never fully completed a project
- **Toolchain installed:**
  - Visual Studio Build Tools 2022 (17.14.35) with the C++ workload (VCTools), including
    both Hostarm64->x64 and Hostx64->x64 compilers
  - x64dbg (was already present on the system)
  - Microsoft OpenJDK 21 (aarch64 build, matching the ARM64 host) - required by Ghidra
  - Ghidra 12.1.2 (PUBLIC, 2026-06-05) - extracted to `tools/ghidra_12.1.2_PUBLIC/`,
    launch with `ghidraRun.bat`
  - Tolk - cloned to `tools/tolk/` (source + prebuilt SAPI/NVDA-controller DLLs; `Tolk.dll`
    itself still needs to be built from `tools/tolk/src/` when we write the hook DLL)
  - MinHook - cloned to `tools/minhook/` (source + CMake, hooking library for intercepting
    game functions)
  - Skipped Cheat Engine (not on winget, installer bundles unwanted offers) - x64dbg covers
    the same memory-scanning/debugging needs for this project

## Why this project deviates from the template

MelonLoader (the template's default mod loader) only works with Unity. Thumper is a
native-engine game, so this project uses reverse engineering (Ghidra/x64dbg/Cheat Engine)
and DLL injection instead. See `CLAUDE.md` -> "IMPORTANT: This project does NOT use the
standard template workflow" for details.

## Feature Plan

1. **Phase 1 (in progress): Main menu narration** via Tolk
2. **Phase 2 (future): Gameplay auto-play assist** for tough sections

## Current Milestone (updated 2026-09-18): PHASE 1 MENUS WORKING

**Menus now speak through NVDA.** This was achieved by *screen reading*, not by reverse
engineering - see `notes/session-2026-09-18-screen-reading-breakthrough.md` for the full
method and the many non-obvious gotchas.

Run it with:
```
tools\narrator\Start-Narrator.cmd
```
This is the **only** entry point. `Start-Narrator.ps1` was deleted - having two similarly
named launchers was confusing about which one actually starts speech.

**Distribution:** the repo does not bundle `nvdaControllerClient32.dll` (NV Access's to
distribute, not ours). The narrator looks for it at `lib/nvdaControllerClient32.dll`, then
falls back to `tools/tolk/libs/x86/`, and exits with a clear message if absent. `lib/` is
gitignored. `INSTALL.md` has the full setup.

**Git:** the repo is `git init`ed with **no commits** - deliberately. The user commits from
**WSL** (`/mnt/c/Users/chris/Documents/ThumperAccess`), not Windows-side git, and wants to
choose when history starts. **Do not commit without asking.** `.gitattributes` normalises
line endings to LF so Windows and WSL do not fight. `README.md`, `INSTALL.md` and `LICENSE`
(MIT, Christopher Tavarez) are written and ready. Verified no game binaries, assets or
saves would ever be tracked.
**Use the .cmd, not the .ps1.** PowerShell's default execution policy is Restricted for
this user, so running the .ps1 directly fails with "running scripts is disabled on this
system". The .cmd sets bypass for that one launch only and changes no machine settings. It
also selects 32-bit PowerShell, which is required because the vendored NVDA controller
client is x86 and this host is ARM64. Stop with Ctrl+C or by closing the window.

Starting it again automatically stops any previous instance - two narrators do not fail
visibly, they just talk over each other.

**Speech log:** everything spoken is appended, with timestamps, to `logs/speech.log`
(gitignored). This is the record to read when picking the work back up - it shows exactly
what the game announced and when.

How it works: find the full-width red highlight bar that marks the selected row, split the
row into label and value at its widest gap, OCR each side with Windows' built-in OCR
engine, measure pip sliders geometrically instead of OCRing them, count the menu rows to
derive "item N of M", and speak through `nvdaControllerClient32.dll`.

Announcement format (agreed with the user):
- `"PLAY, item 1 of 4"` - locked entries such as `PLAY +` are excluded from the count
- `"FULLSCREEN, ON, item 1 of 6"`
- `"VOLUME slider set to 3, range 1 to 12, item 1 of 1"`

Verified on: main menu, Options, Audio (slider), Video (toggles, text values, Apply/
Discard). Nested screens and value edits are announced.

Tooling built this session (all reusable):
- `tools/input/SendKey.ps1` - scan-code key injection; Thumper accepts it, so menus can be
  driven programmatically without touching the keyboard
- `tools/capture/Capture.ps1` - screenshots the fullscreen game (self-pruning)
- `tools/ocr/ReadSelection.ps1` - one-shot read of the selected row, with `-XStart/-XEnd`
  for isolating regions; the main debugging tool
- `tools/ocr/ListItems.ps1`, `tools/ocr/ReadSlider.ps1` - diagnostics
- `tools/narrator/` - the narrator itself

**Phase 1 needs no hook, no DLL proxy, no MinHook, and no Tolk.** Reverse engineering is
now only needed for Phase 2 (gameplay obstacle assist), which screen reading cannot solve.

## Previous Milestone (reverse engineering - now parked, see above)

Reverse engineering the menu system. First dynamic-scan session (2026-07-10) done -
menu selection index NOT found as scannable Int32/float; see
`notes/session-2026-07-10-memory-scan.md` for full methodology, negative results, and
a promising press-correlated counter lead. Built a reusable screen-reader-friendly
memory scanner at `tools/scan/MemScan.ps1` (user presses keys in-game on cue, Claude
drives scanner from terminal - x64dbg GUI is not NVDA-accessible).

Switched to static-first analysis (2026-07-13): `THUMPER_win8.exe` successfully
imported into Ghidra and auto-analyzed headlessly (project at
`tools/ghidra_project/ThumperProject`). Note the game exe had to be copied to
`tools/ghidra_input/` first - `analyzeHeadless.bat` has a batch-parsing bug that chokes
on the `(x86)` in the Steam install path. See
`notes/session-2026-07-13-ghidra-import.md` for details/workaround.

Headless string search (2026-07-13) found the UI architecture: Thumper's menus are NOT
per-screen hardcoded logic - they run on a generic node-graph ("flow") scripting system
loaded from `.flow` files (`start.flow`, `options.flow`, ...), with a shared
`UIController` node type (`kUIControllerShowOptions`/`Start`/`Exit`) and navigation
events (`ui_select_start`, `ui_go_back_start/end`). Also found a literal screen-name
table (MainMenuScreen, OptionsScreen, LevelSelectScreen, CreditsScreen, LoadingScreen,
...) at `1401eb718`-`1401eb840`. Cross-reference lookup came back empty for nearly all
matches (likely table-base/indexed access, not resolved by default analysis) - not yet
investigated. Full detail in `notes/session-2026-07-13-string-search.md`.

Headless raw pointer/RVA scan for the screen-name table (2026-07-13, part 3) came back
negative: no absolute pointer and no MSVC-style relative-offset (RVA) reference to the
table exists anywhere in the binary. Best read: screens are likely selected by hashing
the screen name (typical for flow/node-graph engines) rather than by indexing this
table, meaning it's probably debug/label data, not the hook target we want. Deprioritizing
this table; see `notes/session-2026-07-13-table-xref.md` for full method + results.

Same scan repeated against the flow-node event-name cluster AND against 26 known
real localization-key strings (2026-07-13, part 4) - both also came back negative (the
3 raw hits in the flow-node scan were judged noise: one outside any disassembled
function, two matching a coincidental page-aligned `.reloc` value). Three independent
clusters, three scan variants, all empty: this points to a structural limitation (likely
RIP-relative LEA addressing in code Ghidra's auto-analysis never disassembled/found as a
function) rather than to any one table being wrong. Static byte-level scanning for
pointers is now considered exhausted as a technique - see
`notes/session-2026-07-13-flownode-lockey-xref.md`. Pivoting to a dynamic (running-game)
x64dbg session next: a live breakpoint doesn't care whether Ghidra found the code
statically, only that the CPU executes it.

Tried the aggressive-analysis option anyway (2026-07-13, part 5): enabled Ghidra's
"Aggressive Instruction Finder" (hunts for undiscovered code in gaps between known
functions) and re-checked all 51 known strings from every session. Still 0/51 - a
decisive result. This rules out "Ghidra just didn't disassemble the code" and points
instead to these strings being **dead data**: likely leftover debug/logging text from
Thumper's shared flow/node-graph engine library whose calling code was compiled out of
this specific release build. Static analysis of these string clusters is now considered
fully exhausted (4 independent techniques, all negative) - see
`notes/session-2026-07-13-aggressive-analysis.md`. No further static scans planned;
the dynamic x64dbg session is the sole next step for Phase 1.

## Next Steps

1. ~~Level select screen~~ - done, see above (counts still wrong).
2. **Results / rank screen - THE NEXT JOB.** The user's original ask ("if you score an S on
   a section"), and they confirmed they want it announced the same way the menus are now.
   Blocked only on seeing one: it appears after finishing a section, so capture it during a
   real run before designing the reader. Open questions to answer from that capture:
   - Does it have a red highlight bar? If not, the bar-based path does not apply and it
     needs a dedicated reader keyed off the screen title, like `Get-TitleBox` does.
   - Which values are on screen vs already in the save file. Prefer the save file: the rank
     and score are there as exact data, and a file-watcher on `data_0.sav` could announce
     the real rank the moment the game writes it, with no OCR at all.
3. **Decode `savedata/<steamid>/data_0.sav`** - it is plain, unencrypted, length-prefixed
   records containing literal `RANK_S`/`RANK_A`/... strings and int32 scores per level.
   This would give ranks as real data, and allow a file watcher to announce the true rank
   the moment the game saves. Partially mapped; see the session notes.
4. Announce screen titles on transition (currently only the selected row is announced, so
   moving between screens is inferred rather than stated).
5. Occasional polish, both visible in `logs/speech.log`:
   - A row is very occasionally announced without its value on the first read. There is a
     retry fallback now, but it is not perfect.
   - A transient wrong count can be spoken while a screen is still sliding in (observed:
     "PLAY, item 1 of 2" immediately before the correct "PLAY, item 1 of 4"). The
     two-agreeing-reads gate catches most of these; raising `-SettleMs` above its default
     of 180 would catch more, at the cost of announcement latency.
6. Consider a C# rewrite as a single distributable app, and an ARM64 NVDA controller
   client to remove the 32-bit PowerShell requirement.

### Level select screen - WORKING, except item counts

Announces on level change, and F8 reads the section list. Verified:
- `"Level 1, score 115,250, rank A, 14 of 15 sections played, 6 S ranks"`
- `"Level 1 sections: 1 S, 2 A, 3 A, 4 A, 5 S, 6 S, 7 A, 8 B, 9 S, 10 S, 11 C, 12 S, 13 C,
  14 C, 15 not played"`

Both match the screen exactly. The title is located with `Get-TitleBox` (tallest text band
near the top, cropped to its glyph bounds) - hardcoded crop fractions failed both ways and
should not be reattempted.

Announcements now report the **all-time best** alongside the current run, because reporting
only the current run was misleading after a restart:
- `"Level 1, best score 115,250, rank A, 8 S ranks. current run 1 of 15 sections"`
- F8: `"Level 1 best ranks: 1 C, 2 S, 3 S, 4 S, 5 S, 6 B, 7 S, 8 S, 9 S, 10 S, 11 B, 12 B,
  13 B, 14 B, 15 not played"`

This also confirms block 2 = all-time best: it shows 8 S ranks where the current-run block
showed 6, and survived the level 1 restart intact.

Counts on this screen looked correct in the last test ("PRACTICE, item 3 of 3",
"START, item 3 of 3") after switching row grouping from list adjacency to pitch multiples.
Re-check on the level select specifically before closing this out.

**Previously broken: `Get-MenuPosition` counts on this screen.** RESUME/RESTART/PRACTICE
report "1 of 1", "1 of 2", "2 of 2" (should be 1/2/3 of 3). Two fixes were tried and
neither worked - reference pitch taken next to the selection instead of the median, then
grouping rows by pitch multiples instead of list adjacency. Since both failed, the fault is
almost certainly upstream in band detection: the three menu rows are probably not all being
detected as bands at the same time on this screen (background art here is much brighter
than in the plain menus, and `RowCounts` uses a fixed brightness threshold). **Debug band
detection itself before touching the grouping logic again** - dump what `ListItems.ps1`
sees on this screen and compare against the three real rows. Everything else on the screen
works, so this is cosmetic, not blocking.

### Older notes on this screen

`tools/savedata/ParseSave.ps1` **works and is verified** (9 levels; level1 = 115,250 /
rank A / 15 sections / 14 played, matching the screen exactly).

The narrator wiring is written but **the level summary does not announce yet**. Design
agreed with the user: summary automatically, full section list on **F8** (confirmed F8 and
F9 do nothing in-game). The blocker is reading the big "LEVEL N" title:

- Full-width crop of the title band -> OCR returns empty (same failure as a tight "MSAA"
  crop: small text on a wide, mostly blank canvas).
- Centre crop at x 0.25-0.75 with band y 0.03-0.14 -> reads `"LEVELL-"` / `"LEVELA---"`.
  The band reaches into the level-selector pip row below the title, which OCR renders as
  dashes, and the digit is lost.
- Tightening the band to y 0.025-0.115 -> empty again (cut too far).

So the band needs to end just above the pips while keeping the full glyph height. Better
than guessing fractions: locate the title's actual bounding box with `Blobs`/`RowCounts`
(as the menu-row band detector already does) and crop to it, rather than hardcoding
proportions. Do that next.

Also broken on this screen: **`Get-MenuPosition` gives wrong counts here** - it reported
"RESUME, item 1 of 3", "RESTART, item 1 of 2", "PRACTICE, item 1 of 1". The rank-letter
grid and score line above produce extra bands, and the even-spacing run logic then only
extends downward from the selection, so the index is always 1. It needs to ignore bands
that are not part of the RESUME/RESTART/PRACTICE group.

### Parked (Phase 2 only)

- ~~Static analysis~~ - fully exhausted, 4 techniques, all negative.
- **Dynamic x64dbg session** - still the path to real in-memory game state, now needed
  only for Phase 2 gameplay assist. Note this is far more tractable than in July: the
  narrator tooling means Claude can drive input and read resulting state automatically,
  so input/state correlation no longer depends on slow manual reporting.
- DLL proxy / MinHook / Tolk - not needed for Phase 1 at all.
