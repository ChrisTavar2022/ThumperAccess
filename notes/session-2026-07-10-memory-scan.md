# Session Notes 2026-07-10: First memory-scan session (menu selection hunt)

## Outcome: menu selection index NOT found via Int32 scanning. Valuable negative results below.

**IMPORTANT:** All addresses in these notes are heap addresses from ONE game session
(PID of that day). They are dead after a game restart (heap allocation + ASLR). Do not
reuse them. What carries over is the methodology and the negative results.

## Tooling built (reusable)

`tools/scan/MemScan.ps1` - terminal-driven Cheat-Engine-style scanner (built because
x64dbg's GUI is not screen-reader friendly; the user drives the game, Claude drives the
scanner). Modes:

- `Init` - snapshot all MEM_PRIVATE RW regions of THUMPER_win8 (~615 MB at main menu)
- `Filter -Filter changed|unchanged|increased|decreased|eq [-EqValue N]` - narrow candidates.
  First run diffs against Init snapshot (compiled C# diff); later runs re-check the
  candidate list entirely in compiled code (fast even at millions of candidates)
- `List` - print candidates
- `Watch -Address 0x.. -WatchSeconds N` - poll one address, log changes
- `WatchAll -WatchSeconds N` - poll all candidates, log every change with address
  (first sweep silently refreshes stale stored values)
- `Reset` - clear state

State lives in `tools/scan/state/` (candidates.csv + snapshot/). Known-good workflow
validated against Notepad first.

## Narrowing protocol that worked well

User controls the game via remote control (phone chat + PC game), paces one press every
2-4 seconds on request. Alternate:
1. Baseline `Init` at main menu, hands off
2. Press Down once -> `Filter changed`
3. Idle -> `Filter unchanged` x2-3 (kills animation/timer churn)
4. Repeat. 615 MB -> 8.5M -> ~1.1M -> ~20K -> ~500 candidates in ~6 rounds.

Menu does NOT wrap: Down at bottom does nothing (that press must be filtered as
"unchanged", not "changed"). Top item assumed index 0.

## Negative results (falsified hypotheses)

1. **Plain Int32 index at a fixed heap address**: the eq-0 (at top) + eq-1 (one down)
   chain converged to a single address `0x1C46DFE9DF4` which then FAILED live
   verification (sat at 0 during paced presses; blipped 8191 once). Coincidence survivor.
2. **Float index (0.0/1.0/2.0)**: filtering the 114 eq-0 survivors for bit pattern
   1065353216 (1.0f) after one Down press -> 0 candidates.
3. WatchAll on the 521 pre-eq candidates showed NO address stepping 0-1-2-3-2-1-0 with
   presses. Conclusion: selection is likely stored as a pointer to the selected item,
   inside a recreated object, as a byte/short (our scan was 4-byte aligned Int32), or
   derived state we can't see this way.

## Lead worth revisiting

A cluster of ~10 addresses (that session: 0x1C459416320, 0x1C45941643C, 0x1C45941646C,
0x1C4594163B0, 0x1C45941B444, 0x1C45941B4A4, 0x1C45941B600, 0x1C45941B920,
0x1C459430144, 0x1C46CE4ECB8) incremented by exactly +1 (values ~1376250) at discrete
moments matching the user's press pacing (t ~= 40, 48, 55, 60, 67, 72, 77s). Likely
event/sound-trigger counters (menu-move sound?). Not selection state, but whatever
increments them is code that runs exactly on menu navigation - a hook target findable
in Ghidra by data-access xref if we re-locate such a counter live and break on write
(x64dbg) in a future session.

## Community research (done, dead end for menus)

- Thumper Modding Tool (CocoaMix86, GitHub) = file-based level modding via cache folder,
  no memory internals
- fearlessrevolution has only a REQUEST thread for Thumper (no published table); site
  blocks automated fetching. MrAntiFun trainer exists (health/speed/slowmo) - binary,
  gameplay-only, no menu state
- Thumper Discord is the place to ask if we ever want community help

## Recommended next approach (static-first)

Dynamic scanning stalled; switch to Ghidra static analysis, which needs NO game running
and NO user key-pressing:
1. Import `THUMPER_win8.exe` into Ghidra (tools/ghidra_12.1.2_PUBLIC, launch
   ghidraRun.bat; JDK 21 installed system-wide). Consider headless analyzeHeadless for
   batch analysis.
2. Search defined strings for menu labels ("PLAY", "OPTIONS", "EXIT", "LEVEL", "AUDIO",
   etc.) and font/text-format strings.
3. Xref from menu label strings -> menu construction code -> selection state writes.
4. Alternative target: text-rendering function (hook it, read every string drawn =
   general narration path).
5. Then ONE short dynamic session with x64dbg write-breakpoints to confirm.
