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
- `docs/ACCESSIBILITY_MODDING_GUIDE.md` patterns that assume Harmony/MonoBehaviour

Instead, this project uses **native reverse engineering + DLL injection**:

- **Static analysis:** Ghidra, to find menu/text-rendering and gameplay-pattern functions in
  `THUMPER_win8.exe`
- **Dynamic analysis:** Cheat Engine / x64dbg, to find live memory addresses for menu state,
  song/track position, and obstacle data while the game runs
- **Hook DLL:** written in C++ (MSVC via Visual Studio Build Tools), using a hooking library
  (MinHook) to intercept relevant game functions
- **Injection:** DLL proxying - likely replacing `openvr_api.dll` (VR isn't used in normal
  play) with a proxy that forwards all real calls through and loads our hook on startup
- **Screen reader output:** Tolk, called directly from the native C++ hook DLL (Tolk is a
  native library, no .NET interop needed here)
- **Build:** no `.csproj` - this will be a Visual Studio / MSBuild native DLL project (exact
  setup TBD once the toolchain is installed)

`decompiled/`, `game-api.md`'s "Safe Keys" grep patterns, and the C# code templates in
`templates/` still apply *conceptually* (documenting findings, avoiding key conflicts,
Handler-per-feature structure) but concrete code will be C++, not C#.

## Feature Plan

1. **Phase 1 (current): Main menu narration** - hook into Thumper's menu system, read
   currently selected menu item aloud via Tolk when it changes. First milestone - proves
   the injection + hook + Tolk pipeline end to end.
2. **Phase 2 (future): Gameplay obstacle auto-play assist** - for a chosen tough section,
   read the upcoming track/obstacle data ahead of time and have the mod take over input to
   play that section automatically. Needs reliable extraction of track/pattern data and
   input simulation - much bigger scope than Phase 1, revisit once Phase 1 works.

## Coding Rules

- **Hook/feature classes:** `[Feature]Hook` (C++ analog of `[Feature]Handler`)
- **Private fields:** `_camelCase`
- **Logs/Comments:** English
- **Build:** TBD - native DLL project, not `dotnet build`

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

- `docs/setup-guide.md` - Original template's project setup interview (Unity-specific, kept for reference)
- `docs/localization-guide.md` - Text and announcement localization
- `docs/menu-accessibility-checklist.md` - Menu implementation checklist
- `docs/game-api.md` - Keys, methods, documented patterns (to be filled in as we reverse engineer)
- `templates/` - Original C# code templates (reference only, we're writing C++)
- `scripts/` - PowerShell helper scripts (MelonLoader-specific ones don't apply)
