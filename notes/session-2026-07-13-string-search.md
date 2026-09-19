# Session Notes 2026-07-13 (part 2): Headless string search over the analyzed project

## Outcome: found the UI architecture. Did NOT find a menu-selection variable yet - new,
more promising target identified (the generic "flow" UI system) instead of per-screen code.

## Tooling

`tools/ghidra_scripts/ThumperStringSearch.java` - GhidraScript run via `-postScript`
against the already-analyzed project (`-process THUMPER_win8.exe -readOnly
-noanalysis`). Iterates `DefinedDataIterator.byDataInstance(program,
Data::hasStringValue)`, matches against a menu-label keyword list, prints address +
value + up to 10 xrefs (function name + address) per match.

**API note:** `DefinedDataIterator.definedStrings(Program)` does NOT exist in Ghidra
12.1.2 (used in some older tutorials/other versions) - use
`DefinedDataIterator.byDataInstance(program, Data::hasStringValue)` instead.

Command (paths absolute in practice):
```
analyzeHeadless.bat tools/ghidra_project ThumperProject \
  -process THUMPER_win8.exe -readOnly -noanalysis \
  -scriptPath tools/ghidra_scripts -postScript ThumperStringSearch.java \
  -log tools/ghidra_project/stringsearch.log
```

## Results: 353 total matches (66 C++ RTTI type-descriptor noise, 287 real strings)

RTTI noise = MSVC mangled type-descriptor strings of the form `.?AVClassName@@` (class
RTTI names picked up because e.g. "OptionsScreen", "LevelSelectScreen" contain keyword
substrings). Filtered these out with `grep -v 'String: "\.?A'` on the log - kept for
reference since the class names themselves are informative (see below) but they are a
different kind of hit than literal drawn/loaded text.

### Screen name table (key finding)

Tight cluster of literal strings, `1401eb718` - `1401eb840`, spaced ~16-32 bytes apart -
almost certainly one array/struct table (name + probably a factory fn ptr or type id):

- AutoLoadScreen (1401eb718), CreditsScreen (1401eb728), OptionsScreen (1401eb7b8),
  LevelSelectScreen (1401eb7d8), MainMenuScreen (1401eb7f0), LoadingScreen (1401eb810),
  TitleBackground (1401eb830), UILoadingScreen (1401eb840)

### UI is data-driven via a generic node-graph ("flow") system, not per-screen code

- Loadable graph files referenced as strings: `start.flow`, `options.flow`,
  `menu_path_colors.flow` (NOT present as loose files on disk - packed into hash-named
  `.pc` cache files, consistent with prior community-research finding in
  `notes/session-2026-07-10-memory-scan.md`)
- Generic `UIController` flow-node type with named output pins: `kUIControllerShowOptions`,
  `kUIControllerStart`, `kUIControllerExit`
- Generic `UIStart`/`LoadState` flow-node events: `kUIStartPrevious`, `kUIStartCurrent`,
  `kUIStartIn`, `kUIStartStarted`, `kUIStartNumOuts`, `kLoadStateGoBack`,
  `kLoadStateStartLoad`, `kLoadStateUIState`, `kLoadStateWorldState`
- Generic navigation trigger strings: `ui_select_start`, `ui_go_back_start`,
  `ui_go_back_end`
- RTTI confirms a templated `flow::NodeInfoBase<T>` / `flow::NodeInfoNotShared<T>` system
  used for many gameplay AND UI event types (PlayerPower, NewLevel, GateLevel, LoadState,
  UIStart, ...) - this is a general-purpose visual-scripting node system, UI screens are
  just one use of it.

**Implication for Phase 1:** if menu navigation across ALL screens (main menu, options,
level select, pause) funnels through this one shared flow/UIController system, hooking
it once could narrate every menu rather than needing per-screen hooks. This changes the
target from "find each screen's selection index" to "find the flow-node execution
function and/or its current-selection output value."

### Menu/option item ID strings (look like localization keys)

Matches confirmed pattern `ui/thumper.en.credits` (a locale-file path) found elsewhere in
the binary, so these are likely lookup keys into a string table rather than the drawn
text itself:

option_exit, option_controls, option_audio, option_credits, option_video,
option_gameplay, option_quick_restart, pause_resume, pause_restart,
pause_restart_checkpoint, pause_restart_checkpoint_prompt, pause_quit,
pause_quit_prompt, pause_restart_prompt, level_exit, level_select_start,
level_select_restart, level_select_unlocked, main_menu, continue, settings, credits,
level_select, exit_prompt, restart_checkpoint, restart_checkpoint_previous

Also found: `kGameLayerMenu` (1401d3f30) - a named menu UI layer, and `GameSettings`,
`GameplayMode` enums.

## Known gap: cross-reference lookup came back empty for nearly every match

`getReferencesTo(address)` returned 0 xrefs for almost all hits, including the screen
name table. Likely cause: code accesses these via a table base address / computed index
rather than a direct per-element instruction operand, which Ghidra's default Reference
analyzer pass doesn't always resolve. NOT yet investigated further.

## Next steps

1. Manually inspect the memory region around `1401eb700` (just before the screen-name
   table) in the Ghidra GUI (`ghidraRun.bat`) for the table's structure and find what
   code references the table's base address (not each entry) - that code is very likely
   the screen factory/registry, a strong hook target.
2. Locate the flow-node execution/dispatch function (search xrefs to `UIController` /
   `kUIControllerShowOptions` etc. constant strings or their hash, if the game hashes
   node names instead of comparing strings directly).
3. One short dynamic x64dbg session (as previously planned) - but now with a much better
   target: breakpoint around `ui_select_start` / `ui_go_back_start` execution instead of
   blind memory scanning, since we now know these are the named navigation trigger
   events. This should land directly in the flow-node dispatcher.
4. Prototype the DLL proxy (still pending, unblocked by any of the above).
