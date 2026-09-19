# Session Notes 2026-07-13 (part 4): Flow-node and localization-key pointer scans

## Outcome: both negative. Combined with the screen-name table scan (part 3), we now
have THREE independent static scans, over three different string clusters, all finding
no live reference anywhere in the binary. This is itself a meaningful result - see
Interpretation below for what it implies and the recommended pivot.

## Scan 1: flow-node event-name cluster (`tools/ghidra_scripts/ThumperFlowNodeXref.java`)

Same absolute-pointer + RVA raw-scan technique as the screen-name table (part 3),
targeting the tight string cluster `1401e8c78`-`1401e9f48` (`kLoadStateNumOuts`,
`kUIControllerShowOptions`, `kUIStartCurrent`, `ui_select_start`, `ui_go_back_start`,
plus fallback messages like `"Could not find UIStartEvent value %i"`).

Result: 3 raw matches, all judged noise on inspection:
- One in `.text` (`140050ecb` -> `1401e9695`) with **no containing function** - i.e. not
  inside any code Ghidra actually disassembled/recognized, so not a real instruction
  operand; more likely an accidental byte-alignment match from scanning every single
  byte offset (unaligned) through raw instruction bytes.
- Two (`.rdata` and `.reloc`) both pointing to the exact same page-aligned address
  `1401e9000` (0x1000-aligned) - consistent with a normal PE relocation table "PageRVA"
  block header, not a real reference to our string cluster. Our scan range
  (`0x1401e8c78`-`0x1401e9f48`, ~4816 bytes) is wider than one page (4096 bytes), so it
  was near-guaranteed to contain some page's boundary value by pure chance.

## Scan 2: localization-key strings (`tools/ghidra_scripts/ThumperLocKeyXref.java`)

Different technique this time: exact-address dictionary lookup (not a byte range) for
26 known real, runtime-used localization keys (`main_menu`, `option_exit`,
`pause_resume`, `credits`, `settings`, `continue`, `level_select`, etc. - the
`ui/thumper.en.credits`-style lookup keys, confirmed genuinely used by the running game,
unlike the flow-node debug/tooling strings). Exact-address matching avoids the
page-alignment false positives seen in scan 1.

Result: **0 matches** out of 4,307,822 addresses scanned, for either the absolute-VA or
RVA pointer form. Clean negative - no coincidental noise possible with exact matching.

## Interpretation: static byte-level scanning has hit its limit, not the game

Three different clusters, three different scan techniques (byte range + exact address,
absolute VA + RVA), all say the same thing: nothing in the compiled binary stores a
literal pointer value equal to any of these strings' addresses. But we know the game
obviously does use these strings at runtime (they're real menu text/lookup keys). The
missing piece is almost certainly **RIP-relative LEA addressing** - the standard way
x64 code loads the address of nearby static data. That instruction form encodes a
32-bit *displacement relative to the next instruction*, not the target's absolute
address or any fixed offset - so it can never show up in a byte-level scan for a
constant value, no matter how the scan is shaped.

Ghidra's disassembler normally resolves RIP-relative LEA automatically and creates a
data reference from the instruction to computed target - which is exactly the
`getReferencesTo()` xref mechanism that already came back empty for every one of these
strings (`session-2026-07-13-string-search.md`). The most consistent explanation left:
the actual code that touches these strings was **never disassembled by Ghidra's
auto-analysis** in the first place (so there's no instruction for a reference to attach
to) - plausible for a binary that leans on RTTI-heavy virtual dispatch / function-pointer
tables (already seen in the RTTI noise), since Ghidra's default function discovery
mostly follows direct calls/jumps from known entry points and can miss functions only
reached indirectly.

## Recommendation: stop scanning statically, switch to a dynamic (running-game) session

A live debugger breakpoint sidesteps this entirely - it doesn't matter whether Ghidra
disassembled the right function, only that the CPU actually executes it. Setting a
**data/hardware breakpoint** on one of these known, confirmed-real string addresses
(e.g. `option_exit` @ `1401eac20`) while the game is running and navigating its options
menu would catch the real instruction and function the moment the game reads it -
directly answering the question three static scans couldn't.

This was already Next Steps item 3 from the prior session, just moved up given these
results. It requires the user to actually launch the game and navigate menus on cue
(same call-and-response pattern as `tools/scan/MemScan.ps1` from the 2026-07-10 dynamic
session), since x64dbg's GUI is not NVDA-accessible and needs to be driven via its
command-line/scripting interface instead.

## Next steps

1. ~~Screen-name table~~, ~~flow-node event names~~, ~~localization keys~~ - all static
   pointer/RVA scans exhausted, all negative. Do not repeat this technique on more
   string clusters; the limitation is structural (RIP-relative addressing + Ghidra
   function-discovery gaps), not specific to any one table.
2. Dynamic x64dbg session: set a breakpoint on read access to a confirmed real string
   like `option_exit` (`1401eac20`) or `main_menu` (`1401ea6f0`), have the user open
   the corresponding menu in-game, and capture the triggering instruction + containing
   function from x64dbg's command-line interface.
3. (Optional, static alternative) Re-import into Ghidra with more aggressive function
   discovery (e.g. force disassembly of unreached `.text` bytes) to see if that
   surfaces the missing code - lower priority than the dynamic session since it does
   not guarantee success and dynamic breakpoints are more direct.
4. Prototype the DLL proxy - still unblocked, independent of the above.
