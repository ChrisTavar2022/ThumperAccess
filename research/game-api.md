# Thumper - Reverse-Engineered Game API

Findings go here as we discover them via Ghidra (static) and Cheat Engine/x64dbg (dynamic).
Every entry must be a confirmed finding, not a guess - note how it was found.

## Overview

- Game: Thumper, Drool LLC
- Engine: Custom native C/C++, SDL2 (windowing/input), FMOD (audio), OpenVR (optional VR)
- Executables: `THUMPER_win8.exe` (x64, default), `THUMPER_dx9.exe` (x64, DX9 fallback)

## Memory Addresses / Offsets

(none confirmed yet)

### 2026-07-10 dynamic scan - menu selection NOT found (negative result)

A full Int32 scan session for the main-menu selected-item index came up empty. Ruled out:
plain Int32 index at a fixed heap address, and float index (1.0f bit pattern). No address
tracked the selection stepping 0->1->2->3 with paced arrow presses. Selection is probably
a pointer-to-selected-item, a byte/short, or derived state invisible to a 4-byte-aligned
scan. Full detail, methodology, and a promising press-correlated counter lead are in
`notes/session-2026-07-10-memory-scan.md`. Next: Ghidra static analysis (string xrefs to
menu labels; text-render function). Scanner tool for future sessions: `research/scan/MemScan.ps1`.

Format for entries:
- **What:** e.g. "Main menu selected index"
- **Address/offset:** module + offset, or pointer chain
- **Type:** e.g. int32
- **Found via:** Cheat Engine scan / Ghidra function at 0x...
- **Notes:** stability across restarts, ASLR considerations, etc.

## Functions of Interest

(none found yet)

Format for entries:
- **What it does:**
- **Address (module + offset):**
- **Calling convention / signature:**
- **Found via:**
- **Hook plan:**

## Game Key Bindings

(not yet analyzed - Phase 1 doesn't add new input, so lower priority for now)

## Safe Mod Keys

(TBD once key bindings are documented)

## UI System

(not yet analyzed)

## Notes on Injection Approach

- Candidate for DLL proxying: `openvr_api.dll` (VR unused in normal play, so proxying it
  is unlikely to break core functionality) - **not yet verified whether the game only
  loads it conditionally when VR is detected**, which would mean our proxy never loads.
  Need to confirm during dynamic analysis.
