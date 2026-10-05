# Ghidra workspace (Phase 2)

Phase 2 (the gameplay auto-play assist) may need static reverse engineering of the game
exe. This folder holds everything from the July 2026 Ghidra sessions that can be
published, plus how to rebuild the local workspace those sessions used.

## What is in the repo and what is not

In the repo:
- `research/ghidra_scripts/` - the headless analysis scripts we wrote
- `research/ghidra/results/` - each script's own output, taken from the July 2026 run
  logs (Ghidra's startup noise and local paths left out)
- `research/game-api.md` and `notes/session-2026-07-*.md` - what the results mean,
  including the negative results

Never committed (gitignored, rebuilt locally):
- `tools/ghidra_12.1.2_PUBLIC/` - Ghidra itself, about 900 MB. Free to download.
- `tools/ghidra_input/THUMPER_win8.exe` - a copy of the game exe. It belongs to Drool,
  so it must never be published.
- `tools/ghidra_project/` - the analysed project. It contains the whole game exe plus its
  disassembly, so the same rule applies.

## Rebuilding the workspace

1. Install a 64-bit JDK 21 (Ghidra 12.1 needs it).
2. Download Ghidra 12.1.2 from https://github.com/NationalSecurityAgency/ghidra/releases
   and extract it so you have `tools/ghidra_12.1.2_PUBLIC/`.
3. Copy `THUMPER_win8.exe` from the Thumper install folder to
   `tools/ghidra_input/THUMPER_win8.exe`. Copy it rather than importing from the install
   folder directly: `analyzeHeadless.bat` breaks on the parentheses in
   `Program Files (x86)` (see `notes/session-2026-07-13-ghidra-import.md`). The July copy
   was 3,973,512 bytes; a different size means the game has updated since, and old
   addresses in the notes may no longer match.
4. Import and auto-analyse (about a minute):

   ```
   tools/ghidra_12.1.2_PUBLIC/support/analyzeHeadless.bat tools/ghidra_project ThumperProject -import tools/ghidra_input/THUMPER_win8.exe -log tools/ghidra_project/analyze.log
   ```

5. Run a script against the saved project, for example:

   ```
   tools/ghidra_12.1.2_PUBLIC/support/analyzeHeadless.bat tools/ghidra_project ThumperProject -process THUMPER_win8.exe -readOnly -scriptPath research/ghidra_scripts -postScript ThumperStringSearch.java -log tools/ghidra_project/stringsearch.log
   ```

   (The July sessions kept the scripts in `tools/ghidra_scripts`; they live in
   `research/ghidra_scripts` now.) Use absolute paths if a relative one is rejected.
