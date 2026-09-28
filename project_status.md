# Project Status - Thumper Accessibility Mod

Current state and next steps. The full history - methods, measurements, negative results,
and why each design decision was made - is in the dated files in `notes/`, newest first.

## Current state (2026-09-28): v1.0.0 released publicly

Published 2026-09-28: the repo is public, and release v1.0.0
(https://github.com/ChrisTavar2022/ThumperAccess/releases/tag/v1.0.0) carries
`ThumperAccess.zip`, verified end to end (anonymous download; an older install found and
installed it through the self-updater). To ship an update: bump `VERSION`, run
`tools\setup\Build-Release.ps1 -Zip`, commit, push and `gh release create vX.Y.Z
dist/ThumperAccess.zip` - both from WSL, where the GitHub login lives.

Phase 1 (menus read aloud through NVDA) is feature-complete. It works by screen reading -
screenshot, find the selection highlight, OCR it with Windows' built-in OCR - plus reading
Thumper's unencrypted save file for exact scores and ranks. No reverse engineering, hooks
or DLL injection. See `README.md` for how it works and `INSTALL.md` for setup.

Run it with `tools\narrator\Start-Narrator.cmd` - the only entry point (it bypasses the
default script execution policy for that one launch and selects 32-bit PowerShell, which the
x86 NVDA controller client needs). Everything spoken is logged to `logs/speech.log`.

### Working

- Main menu, Options, Gameplay, Controls, Audio, Video, Credits, pause menu, dialogs, with
  values, pip sliders and "item N of M"
- Level select: level summary (best score, rank, S count, current run progress)
- Leaderboards: level title and each row (rank, name, score)
- "Restart from checkpoint?": each checkpoint with that section's own rank and points
  (`"Level 1, checkpoint 6, rank S, 6,000 points"`, `"checkpoint 7, not played yet"`)
- Section results, announced from the save file the moment the game saves after a section
  - only the rank letter (`"S"`), by design so nothing long plays mid-gameplay - verified live 2026-09-28
  (sections 7-11 spoken B, S, A, S, B, matching the save exactly)
- Distribution: auto-detected install path (`config\game-dir.txt` override), auto-start
  with the game, release packager (`tools/setup/Build-Release.ps1`), self-updating from
  GitHub Releases

### Known limitations (not bugs)

- Controls screen: single-letter key bindings (W, A, S, D, R) are not spoken - a confirmed
  Windows OCR limit on isolated single characters (`notes/session-2026-09-27-*`).
- Leaderboards: the gold rank badge is not read; the `Y TOGGLE MODE` / `X TOGGLE VIEW`
  keyboard bindings are unknown and deliberately not guessed.
- Leaderboards level title OCR is occasionally blank on fast paging (8 of 9 announced in
  testing). Reading the pip row under the title would make it exact; measurements are in
  `notes/session-2026-09-20-leaderboards.md`.

## Next steps

1. Announce screen titles on transition (only the selected row is announced today).
2. Polish seen in `logs/speech.log`: a row very occasionally announced without its value on
   the first read; a transient wrong count while a screen is still sliding in.
3. Later: a single distributable app instead of PowerShell scripts, and an ARM64 NVDA
   controller client to remove the 32-bit PowerShell requirement.

## Phase 2 (future): gameplay assist

Read upcoming obstacle data during gameplay and optionally play a chosen tough section
automatically. Screen reading cannot do this - it needs in-memory game state, so it is the
one place reverse engineering is still needed. Static analysis in Ghidra was exhausted in
July 2026 (4 techniques, all negative - `notes/session-2026-07-13-*`); a dynamic x64dbg
session is the next step there. The tooling (`tools/ghidra_scripts/`, `tools/scan/`) is
kept for it.

## Development machine notes

- The dev machine runs **Windows on ARM64**; Thumper's exes are x64 and run under
  emulation. The vendored NVDA controller client is x86, hence the 32-bit PowerShell.
- Installed for Phase 2: Ghidra 12.1.2 (`tools/ghidra_12.1.2_PUBLIC/`, gitignored), x64dbg,
  OpenJDK 21, VS Build Tools 2022. `analyzeHeadless.bat` chokes on the `(x86)` in the Steam
  path - copy the exe to `tools/ghidra_input/` first.
- Synthetic input for testing: `tools/input/SendKey.ps1` (scan codes; Thumper accepts
  them). Never send Enter on an unfamiliar screen - see `CLAUDE.md`.
