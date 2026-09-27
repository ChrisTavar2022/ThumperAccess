# Session Notes 2026-09-27: three regressions fixed, distribution tooling added, one bug open

Long session, driven live against the running game (user playing on a **different machine**
than earlier sessions - see "install path" finding below). Screenshots taken with
`Capture.ps1` turned out to be unreliable for pixel-level diagnosis this session - see the
DPI note before reusing it for that purpose.

## Regression 1 (fixed): Level select summary stopped announcing after visiting Leaderboards

Reported as "level selection screen not reading out." Root cause was three compounding bugs
in `ThumperNarrator.ps1`, all in the shared title-detection logic added 2026-09-20 for
Leaderboards:

1. **Shared dedupe state.** Level select and Leaderboards both wrote `$currentLevel` to
   decide "has the level changed, should I announce again." Viewing Leaderboards for a
   level, then returning to that same level's select screen, looked like "no change" and
   the summary silently never spoke again for that level. Fixed by giving Level select its
   own `$lastLevelSummary` tracker, separate from `$currentLevel` (which Leaderboards still
   owns, for F8).
2. **Identical title pixels across screens.** Level select and Leaderboards can both show
   the literal same "LEVEL 1" title in the same place, so the title-change pixel-profile
   diff sees nothing and the branch dispatch (bar vs. gold vs. mode) never even re-runs.
   Fixed by tracking `$lastWidgetKind` (bar/gold/none) and forcing a re-check whenever it
   flips.
3. **Main Menu jitter starves the 350ms settle window.** Main Menu and Level select both use
   the red bar (same `widgetKind`), so the flip-detector above doesn't fire crossing that
   boundary, and Main Menu's animated background sits under the same title-band crop,
   jittering the pixel-profile diff continuously - the title is never actually re-read while
   sitting on Main Menu, and `$lastLevelSummary` never resets there. Fixed by resetting
   `$lastLevelSummary` directly whenever a confirmed bar-row label is NOT one of Level
   select's own (`RESUME`/`RESTART`/`PRACTICE`/`START`) - ties the reset to the already-
   reliable confirmed-text detector instead of the fragile title-band jitter.

Underneath all three: **the save-file lookup was hardcoded to
`C:\Program Files (x86)\Steam\steamapps\common\Thumper`**, and this machine's Thumper is
under a second Steam library on `E:\`. This alone made `Format-LevelSummary` return `$null`
every time, silently. Fixed properly (not just re-hardcoded to `E:\`, since a hardcoded path
is exactly what broke): `Find-ThumperInstallDir` (now in both `ThumperNarrator.ps1` and
`ParseSave.ps1`) checks, in order: a player override at `config\game-dir.txt` (gitignored,
template at `config\game-dir.example.txt`), then every library listed in Steam's own
`libraryfolders.vdf`, then the single-library default as a last resort.

Verified live end-to-end: Leaderboards(1) -> Main Menu -> Level select(1) now correctly
announces `"Level 1, best score 115,250, rank A, 8 S ranks. current run 14 of 15 sections"`,
and paging to a different level still works.

## Regression 2 (fixed): Audio VOLUME slider stopped announcing its label

Reported live while the user was sitting on the Audio screen. `FindBar` requires 45% of a
row's pixels to match its strict red fingerprint to count that row as "the selection bar."
Thumper's volume slider now has more pips than it used to (confirmed: range is 1-12, not the
1-10 last verified) - a wider/denser widget covers more of each row with white glyph/pip
pixels, and the **middle** third of the real ~50px bar measured only 0.41-0.44 red fraction,
under the 0.45 line. Only an 8px sliver at the very top of the bar passed, far too short to
OCR - hence a blank label, or nothing at all.

Measured (DPI-aware capture, see note below) on the live Audio screen: real bar spans
y=212-262. Red fraction dips to 0.41 in the middle, and is a clean 0 everywhere else on that
same screen outside the bar - wide margin to drop the threshold. Changed `FindBar`'s
threshold from 0.45 to 0.30. Verified live: `"VOLUME, slider set to 8, range 1 to 12, item 2
of 2"` now speaks correctly.

## Important tooling note: `Capture.ps1` is not DPI-aware

Discovered mid-session: `tools\capture\Capture.ps1` prints `SRC_RECT=1920x1080` but actually
*saves* a 1280x720 PNG - it never calls `SetProcessDPIAware()`, so Windows silently
virtualizes/downscales what it sees. This is the same class of trap as the 2026-09-18
"DPI virtualisation silently downscaling captures" finding, just hitting a different script
(the narrator itself does call `SetProcessDPIAware()` and is unaffected). A screenshot taken
this way is fine for **visually recognizing which screen you're on**, but its coordinates
cannot be trusted for anything pixel-precise - measuring bar bounds, pip positions, red
fractions, etc.

For precise live diagnosis, a small ad hoc DPI-aware capture (P/Invoke
`SetProcessDPIAware()` + `CopyFromScreen`, done inline this session rather than editing
`Capture.ps1`) was used instead, then pixel data was sampled/scanned directly rather than
inspected visually - both because it's more precise and because, separately, a GPU-composited
window (Windows Terminal) turned out to screenshot as solid black via plain GDI capture, so
visual screenshots can't always be trusted anyway. **`Capture.ps1` itself was not fixed this
session** - worth adding `SetProcessDPIAware()` to it if it keeps getting reached for for
precision work, but every fix this session that needed exact pixel measurements used the
ad hoc DPI-aware approach instead.

## Distribution tooling added (feature request, not a bug)

- **`config\game-dir.txt`** (gitignored) - player override for the install path, on top of
  the Steam-library auto-detection above. Template at `config\game-dir.example.txt`.
- **Auto-start**: `tools\narrator\Watch-Thumper.ps1` polls for the Thumper process and
  starts/stops the narrator with it. `tools\setup\Install-AutoStart.ps1` /
  `Uninstall-AutoStart.ps1` (+ `.cmd` wrappers) register/remove a per-user, non-elevated
  `AtLogOn` scheduled task (`ThumperAccessWatcher`) that runs it. **Registering the task
  needs a real interactive session** - it failed with "Access is denied" (both
  `Register-ScheduledTask` and `schtasks.exe`) when run from this agent's own sandboxed
  PowerShell tool, but the user ran `Install-AutoStart.cmd` themselves (elevated, via
  right-click) and it registered correctly. Verified after the fact by querying
  `Get-ScheduledTask`/`Get-ScheduledTaskInfo` directly and by confirming
  `Watch-Thumper.ps1` was actually running as a process - **do not rely on reading the
  console window's own output to verify this class of setup script**; Windows Terminal
  renders as solid black to a plain GDI screenshot (GPU compositing), so query the actual
  state (registry/CIM/process list) instead.
- **Player release packaging**: `tools\setup\Build-Release.ps1` copies an explicit runtime
  file allowlist (kept in the script itself - out of date means a silent `throw`, not a
  bad package) into `dist\ThumperAccess\`, strips the dev-only "Layout"/"Notes for
  contributors" sections out of `README.md` (marked with `<!-- dist:exclude -->` /
  `<!-- /dist:exclude -->`), and can zip it. **Smoke-tested standalone**: copied the output
  to a folder outside the repo entirely, dropped in a copy of the NVDA controller client,
  and ran it against the live game - worked with zero hidden dependency on the dev repo.
- **Self-updating**: `VERSION` (currently `0.1.0`) + `tools\updater\Check-Update.ps1` (hits
  the GitHub Releases API for `ChrisTavar2022/ThumperAccess`, never throws - no
  internet/no release yet/GitHub down are all silent no-ops) + `Install-Update.ps1`
  (downloads + `Expand-Archive -Force` over the existing install - never touches `lib\` or
  `config\game-dir.txt` since the release zip doesn't contain either). The narrator checks
  once per launch; if newer, it announces the version and installs on any `F1`-`F12` press
  (reuses F8's key range - only actually diverts F8's normal "read section ranks" behaviour
  while an update is pending, which is rare). **Important implementation gotcha**:
  `Install-Update.ps1` must never call `exit` - it runs in-process via `&` from the
  long-running narrator, and `exit` inside an `&`-invoked script kills the *whole* narrator
  process, not just that call. Success/failure is communicated via normal exceptions
  instead, caught with try/catch in the narrator. No release has been published yet
  (`git tag`/`gh release create` intentionally left to the user - a public, visible action).

## Regression/long-standing bug 3 (fixed): Level select item counts wrong (`RESUME item 1 of 2`, etc.)

User confirmed still broken, live, on Level 2's select screen (RESUME/RESTART/PRACTICE - all
three enabled, should always read 1 of 3 / 2 of 3 / 3 of 3). This is the same bug tracked
since 2026-09-18 (see "Older notes on this screen" below in this file) - being actively
re-investigated this session with a DPI-aware capture, not yet fixed.

**Findings so far, so this is not re-derived:**

- `Get-MenuPosition`'s row scan (columns 0.28-0.72 of width) picks up a real, reproducible
  **4th spurious band** on Level 2's select screen, sitting just above RESUME
  (measured this session: Top=725 Bot=784, right at `RowCounts`' `maxBandH` cutoff of 65px)
  - background beam art bleeding into the grey-detection test (`grey >= 25`). It has
  `Bright=0` for its entire height, though, so it correctly fails the `enabled = Bright >
  Grey` check and does NOT inflate the position/total on its own.
- Ran the **full** `Get-MenuPosition` algorithm (band-building + slot-grouping +
  enabled-counting) against one real captured frame by hand: it produced the **correct**
  `item 3 of 3` for PRACTICE on that frame, despite the spurious band being present and
  getting slotted in (at `k=-3`) - it's excluded from the count via the `enabled` check as
  above. So the spurious band, alone, does not explain the bug on this frame.
- The observed live symptom is **under**-counting (`1 of 1`, `1 of 2`), not over-counting -
  that points toward a real row sometimes failing to register as its own band at all, e.g.
  two adjacent rows (RESUME/RESTART, or RESTART/PRACTICE) momentarily fusing into one
  band taller than `maxBandH` (65px) during some frame of the animation and getting dropped
  entirely by the height filter - which would cascade into wrong `refGap`/slot grouping for
  whatever survives.
- Inspected the real RESUME/RESTART gap pixel-by-pixel (y=828-846, the ~20px silence between
  the two rows' text): mostly clean zeros, but **not perfectly silent** - a faint 4px-tall
  grey blip at y=835-838 (~56-57 grey pixels/row) sits in the middle of the gap, well short
  of `minBandH` (22px) on its own so it's dropped harmlessly in this frame. Whether this
  blip (or a stronger version of it on a different frame of the animation) ever grows enough
  to bridge the gap and fuse two real rows into one oversized, dropped band is the live
  hypothesis - not yet confirmed with a second frame sample.
Root cause, fully nailed down: a stray blue/purple diagonal track line (part of the
screen's animated background art, not the menu) passes directly through the same
column range (x 0.28-0.72) `Get-MenuPosition` scans for rows, right above the RESUME/
RESTART/PRACTICE block. Its pixels are colorful but happen to have `max-min < 55` (the
existing "grey/desaturated" test's threshold), so they get classified as "grey" - the same
bucket meant for genuinely desaturated locked/disabled menu text. Measured spread on the
real track-line pixels: 24-54, average 47.2 - too close to the "up to 55" cutoff to
separate cleanly with the same test.

This corrupted the count **three different ways across different frames**, all traced live
with real captures and the actual algorithm re-run against each one by hand:

1. The track line's grey bleeds downward into RESUME's real text, on some frames far enough
   that the fused band's total height (66px) lands **one row over** `maxBandH` (65) - the
   whole band, real text included, silently dropped. Only RESTART/RESTART survived ->
   "of 2".
2. On a different frame, the same bleed merged into RESTART's band instead without pushing
   it over the height limit - but added enough to its `Grey` sum that it now *exceeded*
   RESTART's own real `Bright` sum, flipping the `enabled = Bright > Grey` check to false
   and excluding a real, selectable row from the count.
3. On a third frame, a real row's band didn't get detected at all for that single poll -
   likely a genuine transient dip in an actively-animated screen, not something worth
   chasing further given (4) below makes it a non-issue regardless of cause.

Three fixes, all in `ThumperNarrator.ps1`:

1. **`Get-BrightSubBand`** (new function) - when a band comes out taller than `maxBandH`,
   instead of dropping it outright, look for the tallest contiguous run of rows within it
   that qualify on bright pixels alone (every real row measured has had substantial bright
   content; the track-line bleed measured has had none) and keep that sub-run instead, if
   it's itself a normal row height. Fixes failure mode 1.
2. **The `enabled` check is now an absolute floor** (`Bright -gt 200`) instead of a
   relative `Bright -gt Grey` comparison - immune to however much grey noise also happens
   to be mixed into the same band, since real rows measure in the thousands and background
   noise measures ~0. Fixes failure mode 2.
3. **`$script:knownTotal`**, a sticky high-water mark for the item total, reset alongside
   `$lastSpoken` everywhere that already means "the screen changed." A read reporting fewer
   items than a total already confirmed on the same screen is treated as a bad read (the
   count is suppressed for that announcement, the row's label still speaks, next poll gets
   another try) rather than trusted - a real screen's row count does not shrink while you
   sit still on it. This is the backstop that makes the fix robust even against failure mode
   3 (or any other not-yet-seen variant of the same underlying noise), without needing to
   chase every individual manifestation.

Verified live, stable across multiple consecutive polls: `"PRACTICE, item 3 of 3"` on Level
2's select screen (previously "2 of 2").

## Feature removed: F8 / per-section best-rank detail

Deliberate product decision ahead of the v1.0 release, not a bug fix - the user asked for
it removed entirely. `Format-LevelDetail`, its F8 key handler, `$f8Was`, and the now-dead
`$currentLevel` (it existed only to feed F8; nothing else ever read it) are all gone from
`ThumperNarrator.ps1`. The level summary itself (score/rank/S-count/current-run) is
unaffected. All README.md/INSTALL.md mentions removed too.

## Full regression pass (post-fix), and two more real bugs found and fixed

With all of the above landed, did a full pass through every screen: Main Menu, Leaderboards
(rows + paging), Options, Video (all 6 rows), Audio (slider), Gameplay, Controls, Credits,
Level Select (cycling + paging). Found two more real, previously-unverified-screen bugs:

**Gameplay screen: `HUD, ON` read "item 2 of 2" instead of "item 1 of 1".** This screen has
no pip-row/score-line under its title the way Level Select does, so the title itself
("GAMEPLAY", Bright sum 14303) sits close enough to HUD's own row (Bright 3204) to survive
every filter and get counted as a second, phantom row. Fixed in `Get-MenuPosition`: after
building the bands list, drop the topmost band - unless it is the selection itself - when it
is far brighter than the rest average out to (titles measured 8800-14300 across every
screen sampled, real rows 3100-3450, a reliable gap). Deliberately did **not** reuse
`Get-TitleBox` for this - checked first, and on the Video screen its wider scan actually
merges the title with the start of FULLSCREEN into one band whose bottom edge sits *past*
FULLSCREEN's real start, which would have reintroduced the exact bug `minRow` was already
tuned to avoid. Verified live: Gameplay now reads `"HUD, ON, item 1 of 1"`, and Video's full
6-row cycle and every other screen tested still read correctly afterward.

**Controls screen (Options -> Controls): fundamentally different layout, needed a dedicated
reader.** Full details of the investigation, the abandoned icon-shape classifier (and why -
measured directly, an arrow's aspect ratio and fill density turned out statistically
indistinguishable from an ordinary letter's; "LEFT"'s own icon turned out to actually be a
down arrow, not left, so assuming label-matches-icon was also unsafe), and the final
scoped-down design are all in the extensive comment above `Read-ControlsValue` in
`ThumperNarrator.ps1` - read that before touching this screen again, do not re-derive.
Summary of what shipped:

- New `Read-ControlsValue`: reads the value side of a Controls row by OCR-ing each
  right-side blob cluster on its own (cropped tight to its own glyph bounds, not the full
  ~54px bar - the same "small text on a blank canvas" trap `Get-TitleBox` works around
  elsewhere) and keeping only results that look like a real key name. An icon glyph
  reliably OCRs to nothing or garbage and is silently discarded rather than risked.
- `Get-MenuPosition` gained optional `colLeft`/`colRight` parameters (default the existing
  0.28/0.72) - the Controls screen's rows span far outside that centred band (labels start
  around x 0.19, values around x 0.65-0.76), so its reader passes 0.15/0.85 instead.
- Extended the same topmost-band exclusion the Gameplay fix added: it now also drops a
  topmost non-selected band that is implausibly *dim* (Bright <= 200, the same floor the
  `enabled` check already uses), not just implausibly bright. Needed for this screen's grey
  "KEYBOARD" subtitle line (Bright 0), which was never going to count either way but was
  still poisoning `refGap`'s pitch calculation for every row after it - measured live, its
  49px gap to the first row got picked over the real ~59px row pitch, and every row after
  that fell out of tolerance and silently dropped from the count.
- **Known limitation, verified as a hard OCR engine limit, not a bug**: single-letter key
  bindings (W, A, S, D, R) do not get announced - Windows OCR reliably returns nothing for
  an isolated single character regardless of crop tightness or scale (tested up to 25x
  upscaling). Multi-letter bindings (`SPACE`) read correctly. This is a safe degradation,
  not a wrong answer: the row's label and correct position (`"UP, item 2 of 8"`) still
  announce, just without the letter. Revisiting this needs a real letter-shape classifier
  (a bigger undertaking, deliberately not attempted today) or a different OCR engine/API,
  not more crop/scale tuning - that avenue is exhausted.

Verified live: all 8 rows now read `item N of 8` correctly and consistently across repeated
cycling; ACTION and SELECT correctly speak `SPACE`; every other screen re-checked afterward
(Video's 6 rows, Level Select, Leaderboards, Main Menu) still reads correctly.

## Housekeeping

`README.md`, `INSTALL.md`, `CLAUDE.md`, and `project_status.md` were all updated in step
with the above (auto-start usage note, updater usage note, `config\game-dir.txt` override
docs, "install path" now documented as auto-detected rather than a fixed path). See git diff
for exact wording rather than duplicating it here.
