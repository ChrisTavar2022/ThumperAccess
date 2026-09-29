# Thumper Accessibility Mod

## User

- Blind, uses screen reader (NVDA)
- Programming experience: some, has never fully completed a project - explain non-obvious steps, skip basics
- User provides direction, Claude Code writes code independently and explains
- For uncertainties: Ask briefly, then act
- Screen reader-friendly output: NO tables with `|`, use lists instead

## Resume (catch up on an in-progress project)

When the user says **"Resume Thumper"** (or just "Resume" / "Pick up where we left off"):
1. Read `project_status.md` (current milestone + next steps - the source of truth).
2. Read the most recent file in `notes/` (dated session notes with methodology, findings,
   negative results, and open leads).
3. Briefly tell the user, in 2-3 sentences, where we are and what the next step is, then
   continue from there. Do NOT re-run the setup interview.

## Environment

- **OS:** Windows (Bash/Git Bash)
- **Game directory:** auto-detected (checks every Steam library the local client knows
  about) - it is NOT a fixed path, since it differs per machine and has already been seen
  on both `C:\...\Steam\...` and a second library on `E:\...`. A player can override it in
  `config\game-dir.txt` (gitignored, see `config\game-dir.example.txt`) if auto-detection
  ever fails - e.g. a non-Steam install. Don't hardcode this path in new code; call
  `Find-ThumperInstallDir` (defined in both `ThumperNarrator.ps1` and `ParseSave.ps1`).
- **Architecture:** 64-bit (both `THUMPER_win8.exe` and `THUMPER_dx9.exe` are x64; win8 is the default/modern target)
- **Engine:** Custom native C/C++ engine (SDL2 + FMOD), built by Drool LLC. **NOT Unity, NOT Unreal.**

## IMPORTANT: This project does NOT use the standard template workflow

This template is built around MelonLoader, which only works with Unity games (it patches
a compiled C# assembly). Thumper has no such assembly - there is nothing to decompile with
ILSpy/dnSpy and no Harmony patching. The following parts of the template do NOT apply here:

- MelonLoader installation / MelonGame attribute
- `dotnet build [ModName].csproj` as the build command
- Decompiling `Assembly-CSharp.dll` into `decompiled/`

Reverse engineering (Ghidra static analysis, a planned x64dbg dynamic session) was
attempted across several sessions in July and did not find a usable hook point - see
`notes/session-2026-07-*.md` for the full negative results. **Phase 1 no longer needs it.**

## Current approach: screen reading (Phase 1, working)

2026-09-18 found a working alternative that needs no reverse engineering at all - see
`notes/session-2026-09-18-screen-reading-breakthrough.md` for the full method and gotchas,
and `README.md`/`INSTALL.md` for the user-facing description:

- **Capture:** `tools/capture/Capture.ps1` screenshots the fullscreen game (plain GDI
  `CopyFromScreen`, no Desktop Duplication API needed)
- **Read:** `tools/ocr/` finds Thumper's full-width red selection-highlight bar (a global
  UI convention across every menu), splits label from value, and reads each with Windows'
  built-in OCR (`Windows.Media.Ocr`) - sliders are measured geometrically, never OCR'd
- **Drive input (for testing/automation):** `tools/input/SendKey.ps1` injects hardware scan
  codes via `SendInput`, which Thumper (SDL2) accepts as real key presses
- **Save data:** `tools/savedata/ParseSave.ps1` decodes Thumper's plain, unencrypted save
  file directly for exact scores/ranks, instead of OCR-ing the results screen
- **Speak:** `tools/speech/Speak.ps1` / the narrator call `nvdaControllerClient32.dll`
  directly (user-supplied, see `INSTALL.md` - not bundled, `lib/` is gitignored)
- **Entry point:** `tools/narrator/Start-Narrator.cmd` (NOT the `.ps1` directly - see
  `project_status.md` for why) runs `tools/narrator/ThumperNarrator.ps1`, which ties all of
  the above together
- **Build:** none - everything is PowerShell, no compile step

Reverse engineering is parked, kept only for **Phase 2** (see below), where screen reading
genuinely cannot help: it needs upcoming obstacle/track data mid-gameplay, not menu text.

## Distribution (added 2026-09-27, working toward v1.0)

- **Install path:** never hardcode it - call `Find-ThumperInstallDir` (defined in both
  `ThumperNarrator.ps1` and `tools/savedata/ParseSave.ps1`), see "Environment" above.
- **Auto-start:** `tools/narrator/Watch-Thumper.ps1` polls for the game process and
  starts/stops the narrator with it. `tools/setup/Install-AutoStart.ps1` (+ `.cmd` wrapper)
  registers a per-user, non-elevated login task for it; `Uninstall-AutoStart.ps1` removes
  it. Anything launched in the background must go through `conhost.exe --headless`, never
  `-WindowStyle Hidden` - Windows 11 ignores the latter when Windows Terminal is the default
  console, which put a visible window on screen and let the user close (kill) the watcher. **Registering the task needs a real interactive session** - it fails with "Access is
  denied" from an agent's own sandboxed tool calls even though it needs no admin rights; if
  you hit this, ask the user to run `Install-AutoStart.cmd` themselves, then verify by
  querying `Get-ScheduledTask`/`Get-ScheduledTaskInfo` and the process list directly - don't
  rely on reading the console window's output (Windows Terminal renders as solid black to a
  plain GDI screenshot).
- **Player release package:** `tools/setup/Build-Release.ps1` copies an explicit runtime
  file allowlist (kept in the script itself) into `dist/ThumperAccess/` (gitignored,
  regenerate on demand) - no Ghidra/notes/dev tooling. Rebuild it after any change to a
  file it packages, so it never drifts from what's actually shipped.
- **Self-updating:** `VERSION` (repo root) + `tools/updater/Check-Update.ps1` (checks
  GitHub Releases for `ChrisTavar2022/ThumperAccess`, never throws) +
  `Install-Update.ps1` (downloads + merges over the existing install - never touches the
  player's NVDA DLL or `config/game-dir.txt`, since the release zip contains neither; it
  does ship `lib/PUT-NVDA-DLL-HERE.txt` so the folder exists). The zip holds one top-level
  `ThumperAccess/` folder with `/` separators - `Build-Release.ps1 -Zip` writes entries by
  hand because PS 5.1's `Compress-Archive` and `ZipFile` both write backslashes; the updater
  unpacks to temp and copies from that inner folder. **Never call `exit`
  inside a script meant to run in-process via `&` from the narrator** - it kills the whole
  narrator process, not just that call; use normal terminating errors instead, caught by
  the caller. No release has been published yet as of 2026-09-27 (no git tags) - see
  `notes/session-2026-09-27-regressions-and-distribution.md`.

## Pixel-diagnosis gotchas (learned the hard way, 2026-09-27)

- **`tools/capture/Capture.ps1` is not DPI-aware** - it prints the correct `SRC_RECT` but
  actually *saves* a downscaled image (1280x720 instead of the real 1920x1080). Fine for
  glancing at which screen is up; never trust its coordinates for pixel-precise work. For
  that, do an inline DPI-aware capture instead (`SetProcessDPIAware()` + `CopyFromScreen`)
  and sample pixel data directly.
- **A GPU-composited window (Windows Terminal, etc.) can screenshot as solid black** via
  plain GDI capture even though it's clearly visible on the real screen. Don't rely on
  screenshotting a console window to read its output.
- **Geometric shape classification has real limits.** Distinguishing an icon glyph
  (an arrow, an Enter symbol) from an ordinary letter by aspect ratio / fill density /
  mass-distribution does NOT work reliably - measured directly on the Controls screen, a
  real "S" came out statistically indistinguishable from the up/down arrow shapes. Don't
  assume a shape means what its neighbouring label implies, either - "LEFT"'s own icon
  turned out to actually be a down arrow. When correctness matters (a blind player will act
  on what's spoken), an unreliable classifier is worse than not guessing at all - see
  `Read-ControlsValue`'s comment in `ThumperNarrator.ps1` for the full investigation.
- **A widget-detection assumption ("only check gold when no red bar found") turned out
  false.** The "Restart from checkpoint?" screen has a real gold-outline list AND a static
  red bar on screen at once, the only screen that does - `FindBar` matched the static bar,
  and the actually-navigable gold list was never checked. Both are now always checked every
  poll, gold taking priority when found. Before assuming two UI conventions never coexist
  on the same screen, check - a new screen not yet encountered can break that assumption
  without warning.
- **Never send `Enter` while probing an unfamiliar screen's navigation, even once, without
  confirming the confirm-step first.** The checkpoint-restart screen above has no safe
  "just browsing" state despite its own "?" title suggesting one - Enter on it immediately
  restarts gameplay from whichever checkpoint is highlighted. Confirmed the hard way mid
  investigation (no progress was actually lost, but it could have been). Verify a screen's
  actual confirm behaviour with arrow keys and a screenshot first; the "SELECT (Enter icon)"
  corner prompt present on every list-style screen in this game (Leaderboards, this one,
  every red-bar menu) is the tell that Enter always acts immediately here - there is no
  screen anywhere in Thumper's UI with a secondary confirm step.

## Feature Plan

1. **Phase 1 (working):** Main menu, Options, Gameplay, Controls, Audio, Video,
   Leaderboards, Credits, "Restart from checkpoint?" (with per-level current-run section
   ranks), pause menu, dialogs, level select, and settings values are all read aloud via
   NVDA. `F8` (per-section best-rank detail) was deliberately removed
   2026-09-27 ahead of v1.0 - a product decision, not a missing feature. Known limitation,
   not a bug: the Controls screen can't speak single-letter key bindings (W/A/S/D/R) - a
   confirmed Windows OCR limit, see "Pixel-diagnosis gotchas" above. Section results
   are announced from the save file (the game saves after every section - not the results
   screen via OCR) as the rank letter ONLY ("S") - a deliberate user decision so nothing long
   plays mid-gameplay; don't add detail back without asking. Verified live 2026-09-28.
   Screen titles (and dialog questions) are announced on entering a screen since
   2026-09-29 - see `notes/session-2026-09-29-speed-titles-autostart.md`. See
   `project_status.md` "Next steps" for the live list.
2. **Phase 2 (future): Gameplay obstacle auto-play assist** - for a chosen tough section,
   read the upcoming track/obstacle data ahead of time and have the mod take over input to
   play that section automatically. This is the one place static/dynamic reverse
   engineering (Ghidra/x64dbg) may still be needed. Much bigger scope than Phase 1, revisit
   once Phase 1's remaining items are done.

## Coding Rules

- **Language:** PowerShell (no C++/hook DLL - that approach was abandoned, see above)
- **Functions/params:** PascalCase (e.g. `Get-MenuPosition`, `-SettleMs`), standard
  PowerShell verb-noun naming for exported functions
- **Logs/Comments:** English
- **Build:** none - scripts run directly via `tools/narrator/Start-Narrator.cmd`

## Coding Principles

- **Playability, not simplification** - Make game playable as sighted players play it; only suggest cheats when unavoidable
- **Modular** - Separate input handling, UI extraction, announcements, game state
- **Maintainable** - Consistent patterns, easily extensible
- **Efficient** - Cache objects, avoid unnecessary processing
- **Robust** - Use utility classes, handle edge cases, announce state changes
- **Respect game controls** - Never override game keys, handle rapid key presses

## Before Implementation

**ALWAYS:**
1. Search `docs/game-api.md` and `notes/` (memory addresses, function offsets found via
   Ghidra/x64dbg) for actual confirmed addresses/offsets - NEVER guess
2. Use only "Safe Keys for Mod" (see game-api.md -> "Game Key Bindings") if we ever add new
   input, though Phase 1 doesn't need any

## References

- `README.md` - Public-facing project description (status, how it works, credits)
- `INSTALL.md` - End-user setup instructions (NVDA Controller Client, running the narrator,
  auto-start, self-updating)
- `docs/game-api.md` - Reverse-engineering findings (Ghidra/x64dbg), kept for Phase 2
- `notes/session-2026-09-18-screen-reading-breakthrough.md` - The screen-reading method and
  every non-obvious gotcha behind it; read before changing the narrator
- `notes/session-2026-09-28-section-results-and-checkpoints.md` - The two save slots, section
  results from the save file, and the checkpoint screen's per-row detail and skipped-row fixes
- `notes/session-2026-09-27-regressions-and-distribution.md` - Root causes for all four
  2026-09-27 bug fixes, the abandoned icon-classifier investigation, and the distribution
  tooling added that session; read before touching `Get-MenuPosition`, `FindBar`, the
  level-select/Leaderboards title logic, or the Controls screen again
- `tools/narrator/`, `tools/ocr/`, `tools/capture/`, `tools/input/`, `tools/savedata/`,
  `tools/speech/` - The working Phase 1 implementation (see "Current approach" above)
- `tools/setup/`, `tools/updater/`, `config/`, `VERSION` - Distribution tooling (see
  "Distribution" above)
- `tools/ghidra_scripts/`, `tools/scan/MemScan.ps1` - Phase 2 reverse-engineering tooling
