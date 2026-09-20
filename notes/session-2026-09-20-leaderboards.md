# Session Notes 2026-09-20: Leaderboards screen - WORKING

## Outcome: the Leaderboards screen now reads aloud. It needed a second selection-widget
## detector, because this is the one screen that does not use the red highlight bar.

## The finding that mattered: a different selection widget

Every screen handled so far marks the selected row with a **full-width, bright saturated
red bar**. The Leaderboards screen does not. It marks the selected row with a **thin gold
rounded-rectangle outline** - a border, not a fill. `FindBar` therefore returns nothing
here, which is exactly why the narrator was silent on this screen.

Measured border colour on a real capture: peak **(129, 109, 0)**. The signature is *R and
G both raised and close to each other, with B at zero*. That is what separates it from the
red bar, where R is far above both G and B. `IsGold` in `ThumperNarrator.ps1` encodes this
as `r>70 && g>55 && b<50 && |r-g|<45 && r>=g`.

Because it is an outline, the detector cannot look for the longest run of matching rows
the way `FindBar` does. The box is **two thin edges (~4px each) with ordinary row content
between them**. `FindGoldBox` looks for a *pair* of thin gold bands separated by a gap in
the range a row occupies, and returns the region strictly inside the border. Measured box
interior at 1920x1080: 42px tall.

## Hard-won detail (do not re-derive this)

**The row split must use the near-white test, and must ignore the screen margins.**

A leaderboard row is `rank + name` on the left and `score` on the right, separated by a
wide gap, so it is split and OCR'd in two halves like a settings row. The first version
found that gap with a loose "is there content here" threshold (`r>150 && g>130 && b>100`)
scanning the full screen width. It worked in every static test and then failed
intermittently in the live narrator, announcing **"3,280,000"** for what should have been
*"rank 3, KEVINGEM, 280,000"*.

Cause: Thumper's background animates constantly, and its bright beams sweep *through* the
gap between name and score. A loose threshold counts those beams as content, which chops
the real gap into short runs - and then the widest remaining gap is the empty **screen
margin to the left of the list**. The split lands at x≈0, the entire row goes to the
"score" side, the name is discarded, and the rank digit is glued onto the front of the
score by the digit-extraction step.

Two fixes, both needed:
- Use the same **near-white** test as the rest of the codebase (`r>180 && g>150 && b>150`).
  Background beams are red-dominant and fail it; glyphs pass it.
- **Ignore the run that starts at the left screen edge.** That is the margin outside the
  list, never the gap inside a row.

This is the same lesson as the 2026-09-18 "never fingerprint raw pixels" finding, in a new
place: *anything that samples this game's pixels loosely will eventually catch the
background.*

There is also a defensive fallback in `Read-LeaderboardRow`: if the left half does not
parse as `<digits> <name>`, the two halves are rejoined and parsed as one string, so a bad
frame can never again speak a mangled number.

## Score numbers must be rebuilt from digits

OCR returns the thousands separator as `,` on one frame and `.` on the next - the same row
read twice gave `653,050` and `653.050`. Spoken raw, the second becomes "six hundred fifty
three **point** zero five zero". So the score is stripped to digits and reformatted with
`ToString("N0", InvariantCulture)` rather than trusting what OCR returned.

## Announcement format (agreed with the user)

- Row: `"rank 11, SINTHREX, 279,300"`
- Screen: `"Level 2, GLOBAL RANKING"` on entry and whenever left/right pages to another
  level.

**There is deliberately no "item N of M" on this screen**, unlike every other menu. The
row's own rank number *is* its position, and the list runs to hundreds of entries, so a
total would be both unknowable and useless.

## Telling Leaderboards apart from Level select

Both screens have a `LEVEL N` title, so the title alone cannot distinguish them - and
announcing the save-file level summary on the leaderboard would be wrong. Discriminators:

- Level select **always** has the red bar (RESUME/RESTART/PRACTICE). Leaderboards never
  does.
- Leaderboards names its mode under the level pips: **`GLOBAL RANKING`**. That line is
  OCR'd (band 0.19-0.26 of screen height, cropped to its glyphs) and matched for `RANK`.

The mode line is read rather than hardcoded on purpose: `Y = TOGGLE MODE` presumably
switches it to something else (friends?), and reading it means that works for free.

The title check cannot rely on the gold box being present, because the board shows
**`LOADING`** for ~1-2s after entry, before any row exists.

## Verified working

Level 1 and Level 2 global rankings, driven with synthetic input:
- `rank 3, KEVINGEM, 280,000`
- `rank 4, TAIMETMAINTAILLER BUGLE, 279,800` (long name)
- `rank 7, THE [SVK], 279,600` (punctuation)
- `rank 9, SHOCKDEAD DELIRIOUS, 279,300`
- `rank 11, SINTHREX, 279,300` (first row after the list scrolls a page)
- `Level 2, GLOBAL RANKING` then `rank 1, KEVINGEM, 653,050` (left/right level paging)

All cross-checked against screenshots of the same screens.

## Screen layout, for reference

- 10 rows visible at a time. Arrowing past row 10 scrolls the list by one row and keeps
  the selection on the last visible line; up/down chevrons above and below the list show
  when there is more.
- Left/right pages between levels 1-9 via the pip row under the title, and resets the
  selection to rank 1.
- Bottom-left prompts: `Y TOGGLE MODE`, `X TOGGLE VIEW`, `ESC RETURN`.
  Bottom-right: `VIEW PROFILE` on Enter.

## Level change sometimes went unannounced (user-reported, largely fixed)

Reported during live use: paging levels on the leaderboard sometimes did not announce the
new level. Measured before the fixes, paging one level every ~2.6s: **4 of 9 announced**.
After: **8 of 9**. Four separate causes, all found by running with `-Verbose` and reading
what `[title]` actually returned rather than reasoning about it:

1. **The title-change trigger was too coarse.** `TextProfile` bucketed the whole screen
   width into 32 buckets, so changing `LEVEL 2` to `LEVEL 3` - one digit, two glyphs with
   near-identical ink - moved no bucket past the threshold and the read never fired. Fixed
   by giving `TextProfile` an x-range and profiling only x 0.30-0.70, where the centred
   title lives, so the digit is a large share of a bucket. This alone took it from
   "sometimes" to most levels working.
2. **A leaderboard caught mid-load fell into the level-select branch.** The board shows
   `LOADING` for 1-2s after paging, and if the mode line was not readable yet the code
   dropped through to the level-select path, which set `$currentLevel` as a side effect.
   The real `Level N, GLOBAL RANKING` was then suppressed as a duplicate. Fixed by
   requiring the red bar for the level-select branch (level select always has one, the
   leaderboard never does) and retrying instead.
3. **An empty title OCR did nothing at all.** `[title] ''` is a *failed read*, not a state,
   but the old code had no branch for it: not a `LEVEL N` match, and the `elseif
   ($titleText)` reset is skipped because an empty string is falsy. So a blank read simply
   dropped the level change on the floor with no retry. This was the single biggest cause.
   Fixed with a bounded retry when a gold box is on screen.
4. **The retry budget was shared across level changes.** Failures on one level ate the
   allowance for the next, so paging quickly left later levels silent. Fixed by resetting
   the budget whenever the title profile changes.

There is also a belt-and-braces trigger: paging always drops the selection back to rank 1,
so a confirmed `rank 1, ...` announcement forces a title re-check. `$lastBoardKey` stops
that from ever repeating an announcement.

**Still not 100%.** At a fast 2.6s-per-level pace one level in nine is still missed. The
title OCR intermittently returns empty and the retries can be cut short by the next page.
At a human pace it is far more reliable, but if this needs to be bulletproof the next move
is to stop depending on OCR of the title for this: the level-selector pip row under the
title encodes the level positionally (which pip is filled), and counting pips would be
exact, cheap, and immune to the OCR flakiness entirely.

## Known gaps / next leads

1. **The gold rank badge is not read.** Each row ends with a small gold badge (an `S` in
   the boards looked at). It renders as dithered gold, not clean fill, so OCR turns it to
   speckle - it was explicitly excluded from the OCR crop. It needs *measuring/classifying*
   like the volume pips, not reading. The user chose the announcement format without it for
   now.
2. **`Y = TOGGLE MODE` and `X = TOGGLE VIEW` keyboard bindings are unknown.** Those are
   controller-button glyphs; the keyboard equivalents are not documented in
   `docs/game-api.md` and were deliberately **not** guessed. Worth finding, since TOGGLE
   VIEW likely switches to an "around my rank" view, which is the view that actually
   matters to a player. Only `ESC` (RETURN), `Enter` (SELECT/VIEW PROFILE) and the arrows
   are confirmed.
3. **Rows can be skipped when arrowing quickly.** Stepping down every ~1.3s, ranks 5 and 6
   were passed over silently. Each announcement costs two OCR calls plus the settle and
   the confirm re-read, so a fast run outpaces it. Not a correctness bug, but on a long
   list it loses your place. Worth timing the OCR calls before tuning `-SettleMs`.
4. `VIEW PROFILE` (Enter on a row) is untested - unknown whether it opens a screen this
   reader handles.
5. The per-level leaderboard is also reachable from the level select screen via
   `X LEADERBOARDS`; not tested, but it is presumably the same widget.
6. OCR reads `SHOCKDEAD_DELIRIOUS` as `SHOCKDEAD DELIRIOUS` (underscore becomes a space).
   Harmless for speech.

## Observation on the existing wrong-count bug

While testing, the main menu twice announced a wrong count on a first read - `LEADERBOARDS,
item 2 of 3` and `EXIT GAME, item 2 of 2`, both correct on the next pass (`2 of 4`,
`4 of 4`). Notably one of these happened on a **plain in-menu move, not a screen
transition**, which is a data point for polish item 5 in `project_status.md`: the
two-agreeing-reads gate does not catch all of them.
