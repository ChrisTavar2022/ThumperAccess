# Thumper Accessibility Mod

## User

- Blind, uses screen reader (NVDA)
- Programming experience: some, has never fully completed a project - explain non-obvious steps, skip basics
- User provides direction, Claude Code writes code independently and explains
- For uncertainties: Ask briefly, then act
- Screen reader-friendly output: NO tables with `|`, use lists instead

## Project Start

For greetings ("Hello", "New project", "Let's go"):
Read `docs/setup-guide.md` and conduct the setup interview. (Already completed for this project - see below.)

## Resume (catch up on an in-progress project)

When the user says **"Resume Thumper"** (or just "Resume" / "Pick up where we left off"):
1. Read `project_status.md` (current milestone + next steps - the source of truth).
2. Read the most recent file in `notes/` (dated session notes with methodology, findings,
   negative results, and open leads).
3. Briefly tell the user, in 2-3 sentences, where we are and what the next step is, then
   continue from there. Do NOT re-run the setup interview.

## Environment

- **OS:** Windows (Bash/Git Bash)
- **Game directory:** `C:\Program Files (x86)\Steam\steamapps\common\Thumper`
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

## Feature Plan

1. **Phase 1 (working):** Main menu, Options, Audio, Video, pause menu, dialogs, level
   select, and settings values are all read aloud via NVDA. Not done yet: the post-section
   results/rank screen, and announcing screen titles on transition. See `project_status.md`
   "Next Steps" for the live list.
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
- `INSTALL.md` - End-user setup instructions (NVDA Controller Client, running the narrator)
- `docs/setup-guide.md` - Original template's project setup interview (Unity-specific, kept for reference)
- `docs/localization-guide.md` - Text and announcement localization
- `docs/menu-accessibility-checklist.md` - Menu implementation checklist
- `docs/game-api.md` - Reverse-engineering findings (Ghidra/x64dbg), kept for Phase 2
- `notes/session-2026-09-18-screen-reading-breakthrough.md` - The screen-reading method and
  every non-obvious gotcha behind it; read before changing the narrator
- `tools/narrator/`, `tools/ocr/`, `tools/capture/`, `tools/input/`, `tools/savedata/`,
  `tools/speech/` - The working Phase 1 implementation (see "Current approach" above)
- `tools/ghidra_scripts/`, `tools/scan/MemScan.ps1` - Phase 2 reverse-engineering tooling
