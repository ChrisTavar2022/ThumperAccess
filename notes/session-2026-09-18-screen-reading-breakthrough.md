# Session Notes 2026-09-18: screen-reading pivot - Phase 1 menus WORKING

## Outcome: menus now speak through NVDA. Phase 1 is functionally solved without any
## reverse engineering. See "Why this changes the plan".

## What changed

Previous five sessions tried to locate menu state inside the game process (Ghidra static
analysis, then a planned x64dbg session). This session took a different route: read the
screen, not the process. It worked end to end in one sitting.

Three capabilities were proven, in order:

1. **Synthetic input works.** `tools/input/SendKey.ps1` injects hardware scan codes via
   `SendInput`. Thumper (SDL2) accepts them as real key presses. PostMessage-style fakes
   would not have worked; scan codes do. This removed the remote-control lag that made the
   2026-07-10 session so slow - Claude can now drive the menus directly.
2. **The fullscreen game can be screenshotted.** Plain GDI `CopyFromScreen` captures
   Thumper fine. No Desktop Duplication API needed.
3. **Windows' built-in OCR can read the menu.** `Windows.Media.Ocr`, no external
   dependency, no Tesseract.

Plus speech: `nvdaControllerClient32.dll` (already vendored in `tools/tolk/libs/x86`)
speaks directly to NVDA. Tolk itself was never needed - Tolk is a wrapper over this DLL.

## The key insight that makes this generalise

Thumper marks the selected menu entry with a **full-width, bright saturated red bar** and
white text. That bar is a *global* UI convention - the same widget appears in the main
menu, the Options menu, and the Video submenu (all confirmed this session). So the tool is
not a "main menu reader"; it is a "find the highlight bar anywhere and read it" reader,
and it generalised to every screen tested without per-screen code.

## Hard-won details (do not re-derive these)

- **DPI awareness is mandatory.** The dev machine is 1920x1280 at 125% scaling. Without
  `SetProcessDPIAware()` the grab returns a virtualised 1536x1024 view, the capture looks
  cropped at the bottom, and OCR accuracy collapses. This cost real time to diagnose -
  it initially looked like Thumper's menu was overflowing the screen. It was not.
- **`[ushort]` is not a PowerShell type accelerator.** Use `[uint16]`.
- **Bar detection only locks onto the bar's solid core** (~23 of ~60 rows), because the
  bar's top/bottom edges are anti-aliased gradients. Cropping to the detected core slices
  the glyphs in half and OCR returns empty. Crop a fixed band around the bar's *centre*
  instead (`height * 0.028` each way at 1280p).
- **Never fingerprint raw pixels to detect change.** Thumper animates its background
  continuously, so raw pixels differ every single frame even on a still menu. An exact
  hash never repeats and the reader stays silent forever. Even hashing a thresholded text
  mask flickers, because anti-aliased glyph edges cross the brightness threshold frame to
  frame. What works: a **tolerant bucketed column profile** (32 buckets of near-white
  pixel counts) compared with a ~20% difference tolerance, with **bar position change** as
  the primary trigger.
- **The bar slides between rows, it does not jump.** Reading the instant it starts moving
  captures a smeared mid-animation frame. Wait for it to settle (~180ms), then read once.
- **Screen transitions slide the whole list**, so a single read mid-slide sees a partial
  menu and produces a wrong count ("item 2 of 2"). Require **two consecutive agreeing
  reads** before speaking.

## Announcement format (user requirement, raised mid-session)

Speak position, not just text: `"PLAY, item 1 of 4"`.

Locked entries are **excluded from the count**. The main menu draws five rows but
`PLAY +` is locked, and navigation skips it, so the user experiences four. Locked rows are
detectable visually: they render desaturated grey with essentially zero bright pixels
(measured: `PLAY +` = bright 0 / grey 2976, versus `PLAY` = bright 2452 / grey 0).

## Verified working

- Main menu: PLAY 1/4, LEADERBOARDS 2/4, OPTIONS 3/4, EXIT GAME 4/4. No wrap at either end.
- Options: CONTROLS 1/4, VIDEO 2/4, AUDIO 3/4, GAMEPLAY 4/4. This menu *does* wrap.
- Video submenu: "RESOLUTION 1920X1280, item 1 of 5", "FRAME RATE VSYNC, item 2 of 5" -
  label and value are read together, which is the desired behaviour.

## Sliders must be measured, not OCR'd (user-reported bug, fixed)

The Audio screen reads "VOLUME" followed by gibberish. Cause: Thumper draws volume-style
settings as a row of pips - filled capsules up to the current level, hollow rings beyond
it, with left/right arrows on the selected row. OCR turns the rings into "0000000000".

Fix: detect the widget geometrically and clip it out of the label OCR.
- Segment the right half of the bar into white blobs by **column projection** (count white
  pixels per column across the bar rows). This segments cleanly regardless of glyph shape.
- A blob is a **filled** pip if the pixel at its centre, at mid-bar-height, is white; a
  hollow ring has a red centre there.
- **Trim the first and last blob positionally**, not by width. They are the arrows. Width-
  based trimming misfires during the pip-fill animation, when an arrow can momentarily
  measure as wide as a pip - this produced a wrong "7 of 13" reading.
- Reject as "not a slider" if the remaining blob widths are not uniform (within 35% of
  median). That is what stops "RESOLUTION 1920X1280" being treated as a slider.
- Measured layout: 14 blobs = 2 arrows (w20/w21) + 12 pips (w26-28).

**A single pip change does not clear a total-difference threshold.** One pip out of twelve
is ~8% of the row's pixels, well under the 20% tolerance needed to ignore animation
jitter, so slider steps were silently dropped. Fixed by also triggering when any *single*
bucket of the column profile changes by >= 40: jitter spreads thinly across buckets, a pip
toggle concentrates in one.

Verified: stepping the volume announces every step, 3 through 5 and back down, with
correct counts.

## Announcement format (settled with the user)

- Plain row: `"PLAY, item 1 of 4"`
- Slider row: `"VOLUME slider set to 3, range 1 to 12, item 1 of 1"`
- Position is announced **always**, including "item 1 of 1" on single-setting screens.
  An early version suppressed it when there was only one item; the user asked for it to be
  consistent with everything else.

Note: `Get-MenuPosition` originally required >= 2 detected rows and returned nothing on the
Audio screen, which has only VOLUME. Single-band screens are now handled explicitly.

## Save file is plain and parseable - unfinished lead worth pursuing

`savedata/<steamid>/data_0.sav` (8537 bytes) is **not encrypted**. It is length-prefixed
records: int32 length + ASCII string, interleaved with int32 scores. It contains literal
`RANK_S` / `RANK_A` / `RANK_B` / `RANK_C` / `RANK_NONE` strings grouped under `level1`,
`level2`, ... with what look like cumulative per-section scores.

Partial header: offset 0 = 65, offset 4 = 8537 (file size), offset 8 = 1784953354 (a hash
that recurs at offset 55, so probably a per-level id), offset 16 = 9 (Thumper has 9
levels). A naive 4-byte token walker desyncs at offset 54 because there is a single-byte
field there - the schema has mixed field widths.

**Why this matters:** ranks could be read as real data rather than OCR'd off a results
screen, and a file watcher could announce the true rank the moment the game saves after a
level.

### DECODED - `tools/savedata/ParseSave.ps1`

The save parses cleanly and is **cross-validated against the level select screen**.

- **The game has 9 levels** (`level1`..`level9`).
- Sections per level: 15, 22, 26, 30, 29, 24, 19, 27, 28.
- Per level the file holds: overall `RANK_*`, total score, then the per-section ranks.
- **Each level's section ranks are stored twice.** The count of rank tokens per level is
  `2 + 2N` where N is the real section count: two `RANK_NONE` placeholders, then N ranks,
  then N more.
- **CONFIRMED by observation 2026-09-18: block 1 is the CURRENT RUN, block 2 is the
  all-time best.** An earlier guess that block 2 was PLAY+ was wrong. Evidence: before
  playing, block1 for level1 read `S A A A S S A B S S C S C C NONE` and matched the level
  select screen exactly. The user then chose RESTART on level 1 and played one section;
  block1 became `B NONE NONE ...` while the level's overall `score=115250 rank=A` stayed
  unchanged. So the level select screen shows *current run* progress, the overall score and
  rank are all-time bests, and restarting a level does NOT destroy history.
- Consequence for announcements: reporting only block1 is misleading. Saying "Level 1, not
  played yet" while the player holds a 115,250 rank A best is wrong-feeling, and the
  narrator did exactly that at 20:05:49. Announce best ranks as well as current-run
  progress, and make clear which is which.
- Immediately after the two placeholders the file also stores two int32s that read as
  "sections played" and "section count" (14 and 15 for level1) - matching the screen.

Validation: level1 = score 115250, rank A, 15 sections, 14 played, ranks
`S A A A S S A B S S C S C C NONE`, 6 S ranks. level2 = 86950, rank C, 22 sections, 20
played. Both are exactly what the game displays, including the empty trailing boxes.

This means **scores, ranks and section counts should come from the save file, not OCR**.
OCR is only needed to know *which* level is currently selected (the large "LEVEL N"
title), which is big clean text and reads reliably.

Also confirmed: `cache/` holds hash-named `.pc` asset bundles. This independently supports
the 2026-07-13 conclusion that the engine addresses assets by **hash**, which is why the
screen-name string table had no cross-references - it is label/debug data, not a lookup table.

## Why this changes the plan

Phase 1 (menu narration) no longer needs a hook, a DLL proxy, MinHook, or Tolk. The
remaining reverse-engineering need is Phase 2 (reading upcoming obstacles during
gameplay), which screen reading genuinely cannot solve.

One further point in favour of keeping RE alive for Phase 2: the screen reader is also an
*instrument*. Claude can now press a key and read the resulting state automatically,
unattended, hundreds of times. A memory scan correlating input to state is far more
tractable than it was in July, when ground truth depended on the user reporting what they
heard over a laggy remote-control link.

## Next steps

1. Results/rank screen: confirm what the post-level screen looks like and whether it has a
   highlight bar (it probably does not - likely needs a dedicated reader).
2. Decode `data_0.sav` properly - gives real rank data and enables a save-file watcher.
3. Level select screen (behind PLAY) - not yet tested.
4. Announce screen titles on transition, so context changes are obvious.
5. Consider rewriting the narrator in C# as a single distributable app. The PowerShell
   version must run under 32-bit PowerShell on this ARM64 host, because the vendored NVDA
   controller client is x86 - an ARM64 build of the client would remove that constraint.
