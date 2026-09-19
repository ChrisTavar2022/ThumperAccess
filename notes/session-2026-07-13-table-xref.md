# Session Notes 2026-07-13 (part 3): Raw pointer/RVA scan for screen-name table references

## Outcome: negative result. No code or data found that references the screen-name
table's base address, by either an absolute pointer or an MSVC-style relative offset
(RVA). This closes out Next Steps #1 from the string-search session as a dead end (for
now) and shifts priority to Next Steps #2 (flow-node dispatcher).

## Why this was needed

`ThumperStringSearch.java`'s `getReferencesTo(address)` call found 0 xrefs to almost
every string match, including the screen-name table entries (`1401eb718`-`1401eb840`,
see `session-2026-07-13-string-search.md`). That analyzer only catches references Ghidra
resolved as instruction operands during auto-analysis. This session's goal: check for
the table's address stored as raw *data* anywhere in the binary, which a operand-level
xref pass wouldn't necessarily catch.

## Tooling

`tools/ghidra_scripts/ThumperTableXref.java` - GhidraScript run via `-postScript`,
`-readOnly -noanalysis` (same pattern as the string search). Two passes over every
initialized memory block (Headers, .text, .rdata, .data, .pdata, .gfids, .tls, .rsrc,
.reloc, .bind):

1. **Absolute 8-byte pointer scan:** read a `long` at every single address, check if it
   falls in `[0x1401eb6d8, 0x1401eb860]` (the table's known string-entry span, widened
   ~0x40 on each side to catch a possible header/base pointer).
2. **4-byte RVA scan:** same idea, but checks a 32-bit value against the *image-relative*
   equivalent range (`value - imageBase`), since MSVC x64 often stores 32-bit
   module-relative offsets instead of full pointers (notably for RTTI structures - this
   is why the earlier string search saw so much `.?AV` RTTI noise) to avoid needing
   runtime relocations.

Command:
```
analyzeHeadless.bat tools/ghidra_project ThumperProject \
  -process THUMPER_win8.exe -readOnly -noanalysis \
  -scriptPath tools/ghidra_scripts -postScript ThumperTableXref.java \
  -log tools/ghidra_project/tablexref.log
```

## Results

- **Pass 1 (absolute pointers):** 4,307,822 addresses scanned, **0 matches**. No 64-bit
  pointer to this region exists anywhere in the binary's initialized memory.
- **Pass 2 (RVAs):** **2 matches**, both in `.rdata`, both with no containing
  function/symbol found at the storing address:
  - `14022e888` -> RVA resolves to VA `1401eb839`
  - `14022e8bc` -> RVA resolves to VA `1401eb800`
  Both land *mid-string* inside `TitleBackground` (starts at `1401eb830`), not at an
  entry boundary, and neither has anything else pointing to it. Read as likely
  coincidental noise (some unrelated small int32 constant landing in our narrow
  ~392-byte target window) rather than a genuine reference - not acted on further.

## Interpretation

The table is very likely **not walked via any stored pointer at runtime** - neither
approach a compiler would normally use (absolute VA or RVA) shows evidence of it. Given
the project's confirmed flow/node-graph UI architecture (`session-2026-07-13-string-search.md`),
a more consistent explanation is that screens are selected by **hashing the screen name
string** (a common flow-graph/node-system pattern) and comparing against a hash table,
rather than by indexing this string array directly - which would mean this table is
debug/label data (e.g. for a screen-name-to-enum lookup used rarely, like error
messages) rather than the hot path we want to hook.

## Next steps (supersedes item 1 in the prior note)

1. ~~Inspect screen-name table base-address references~~ - dead end, deprioritized.
2. **Locate the flow-node dispatcher** - search for xrefs to `UIController` /
   `kUIControllerShowOptions` / `ui_select_start` etc. constant strings (same
   raw-scan technique now proven out could apply here too if direct xrefs come up
   empty again).
3. One dynamic x64dbg session targeting `ui_select_start` / `ui_go_back_start`.
4. Prototype the DLL proxy (unblocked, independent of the above).
