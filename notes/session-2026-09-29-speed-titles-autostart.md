# Session 2026-09-29 - faster menus, screen titles, auto-start window fix

All testing this session was done live by driving the game with `tools/input/SendKey.ps1`
(with the user's go-ahead) and reading `logs/speech.log`, which now has millisecond
timestamps. Verbose output was captured by starting the narrator hidden:
`conhost.exe --headless <SysWOW64 powershell> -Command "& ThumperNarrator.ps1 -Verbose *> file"`.
Kill the previous instance first - a new one cannot open a verbose file the old one still
holds, and fails silently, leaving the OLD code running (cost one misleading test run).

## Auto-start: visible terminal at login, and auto-start silently dying (real bug, fixed)

User report: a terminal window opened at every login, and sometimes the narrator did not
start with the game. One cause for both. The logon task ran
`powershell.exe -WindowStyle Hidden ...`; on Windows 11 with Windows Terminal as the default
console, `-WindowStyle Hidden` is ignored, so the watcher showed a visible window. Closing
it killed the watcher: `Get-ScheduledTaskInfo` showed `LastTaskResult 3221225786`
(0xC000013A, STATUS_CONTROL_C_EXIT), and no watcher process was running while the game was.

Fix: the task now runs `conhost.exe --headless powershell.exe ...`, and the watcher starts
the narrator the same way. Verified: a narrator started through `conhost --headless` has
no window (`MainWindowHandle` 0) and speaks normally. **The task must be re-registered by the
user** (`tools\setup\Install-AutoStart.cmd`) - registering needs their interactive session.

## Speed

Measured key-to-speech before: ~0.6-0.9s per row, with rows skipped at presses ~0.6s apart.
After: ~0.3s for plain rows; 14/14 Controls presses, 6/6 pause menu, level select and main
menu all announced at 0.65-0.7s spacing. Changes, each found from verbose timing:

1. **First-read trust.** Once a screen's row count is confirmed (`$script:knownTotal`), a read
   that matches it is spoken without waiting for a second agreeing read - the same trade the
   checkpoint screen made on 2026-09-28. A new screen still needs two reads.
   OCR'd values ("1920X1080") still need two: a first read came back "1920xm080". But a
   "LABEL, VALUE" pair confirmed once this session is trusted on later first reads.
2. **`SettleMs` 180 -> 100.** A poll takes ~170ms on the dev machine; 180 cost a second poll
   on every row. The new row's text was complete on the first poll after the bar moved.
3. **Bar-position jitter.** FindBar's top edge flickers 784/785 between frames; `-ne` treated
   that as a move and restarted the settle wait every poll, so LEADERBOARDS was never read.
   Now a move must exceed 3px.
4. **Main menu background taken for the bar.** The animated background periodically floods
   the top of the screen with red rays - runs of 130-260 rows, vs the real ~50-row bar - and
   FindBar took the longest run, so the real bar was lost for seconds at a time. Runs taller
   than 8% of the screen are now skipped.

## Screen titles (next-steps item 1, done)

The first row announced on a new screen is prefixed with the title, in one utterance
(`Say` cancels speech, so a separate title call would cut the row off): "OPTIONS. GAMEPLAY,
item 1 of 5". `Read-ScreenTitle` reuses `Get-TitleBox`, accepts only clean uppercase text,
and skips "LEVEL N" (level select / pause menu already announce their level) - returning
"-" for that case so the row is not held back waiting for a better read.

- **When to read it:** only for the announcement that ends a run of unconfirmed reads
  (`$screenFresh`). Reading on every `$titleDirty` wasted an OCR per row on the main menu,
  whose animated background keeps the title band "changing" and whose logo never OCRs.
- **Title slides in after the row now:** with faster rows, the Controls title was read while
  still sliding in and came back empty. An empty read on a new screen holds the row for up
  to two more polls.
- **Dialogs:** "EXIT GAME?" / "QUIT LEVEL?" sit at ~0.30 of the height, below the title
  zone. `Get-QuestionBox` reads the lowest text-height band above the bar, only when the
  title zone is EMPTY (the main menu's logo keeps it from reading PLAY as a title) and at
  least 0.06h above the bar (the question was ~135px up; a plain row ~20px). A 2px glint just
  above the bar has to be skipped, not taken. Result: "EXIT GAME? NO, item 1 of 2".
- Seen on every screen: OPTIONS, GAMEPLAY, CONTROLS, AUDIO, VIDEO, both dialogs. Main menu
  (logo) and pause menu / level select ("LEVEL 1") correctly say no title.

## Count / completeness fixes (next-steps item 2)

- **Audio "item 2 of 2".** The AUDIO title sits exactly two row pitches above VOLUME and was
  counted. `Get-MenuPosition`'s `minRow` 0.10 -> 0.15 (titles end by 0.14; first rows at
  0.20).
- **Main menu "OPTIONS, item 2 of 3" on return.** The fading EXIT GAME highlight fused into
  its row band and moved its top 11px. Pitch is now measured between band centres.
- **Level select "RESUME, item 1 of 2" / no count.** Background art 42px above RESUME was
  taken as the pitch (the minimum neighbour gap). Now the neighbour gap closest to the normal
  pitch is used - every menu measured is 54-59px at 1080p, ~0.052h.
- **Undercount retry.** A total lower than one already confirmed used to be dropped and the
  row spoken with no count; it is now re-read up to 4 times first.
- **Follow-up reads.** After an announcement missing its value or position, or the first
  row of a new screen, the row is re-read twice ~350ms apart and spoken again only if the
  same row gained a value, a position, or a higher total (a menu still fading in).
- **Level summary cut off (existing bug).** The bar row re-read ~0.15s after the level
  summary cancelled it. That row is now queued behind the summary (`Say -Queue`), within an
  800ms window only, so a real key press still interrupts.

## Short words: "UP" (fixed) and "4X" (not)

Windows OCR returns nothing for a lone short word. Controls' "UP" label - a perfectly clean
binarized crop - was empty on 15 of 16 scale/padding combinations and had never been
announced in the whole speech log. Tiling three copies side by side, half a glyph height
apart, read "UP UP UP" at every scale (`Read-StripTiled`), used only as a fallback for an
empty label, and only accepted when all three copies agree and are uppercase letters.

Negative results, do not retry:
- Tiling the single-letter key bindings: "W" reads, but the up-arrow icon beside it tiles
  to "t t t" - a confident wrong key. Single letters stay unspoken.
- MSAA's "4X": tiled read "ax ax ax"; label+value glued into one line read "MSAA 4X" in
  only some scale/gap combinations and "MSAA ax" in others. Left as a known limitation (it
  was missing in 8 of 9 reads before today too).

## Repo reorganization (same session)

- `tools/` = only what ships to players; `dev/` = SendKey, Capture, Build-Release;
  `research/` = Ghidra scripts, MemScan, `game-api.md`. Deleted the superseded
  `tools/ocr/` prototypes and `tools/speech/Speak.ps1` (dead: referenced a missing Say.ps1).
- `ThumperNarrator.ps1` (1,845 lines) split into startup + main loop, with modules in
  `tools/narrator/lib/`: ThumperVision.cs, Speech, Ocr, ScreenReading, LevelData, Announcer
  (all loop state in one `$S` object; three named poll steps sharing `Test-SelectionChanged`),
  Updates. Re-tested live on every screen: identical output.
- **Player-facing paths under `tools/` must never move:** installed scheduled tasks point at
  `Watch-Thumper.ps1`, the 1.0.0 updater restarts `Start-Narrator.cmd`, and the updater
  never deletes old files.
- `.gitignore`'s `lib/` matched ANY lib folder and silently hid `tools/narrator/lib/` - the
  release would have shipped without the modules. Now `/lib/`.
- The dev machine's NVDA DLL moved from a local tolk checkout into `lib/` (like a player's);
  the narrator's tolk fallback, `tools/tolk` and `tools/minhook` are gone.

## v1.0.1 released

Published 2026-09-29. Verified first by downloading the real v1.0.0 zip and running its own
`Install-Update.ps1` against the new zip via a `file://` URL: files arrived, including the new
`lib/` subfolder, and the upgraded copy ran. A v1.0.0 copy's `Check-Update.ps1` then found
the live release.

Negative result: the narrator cannot fix a 1.0.0 auto-start task itself -
`Set-ScheduledTask` is "Access is denied" from the narrator's process as well as from the
agent sandbox. So `Test-AutoStartTask` (Updates.ps1) speaks a reminder at startup to re-run
`Install-AutoStart.cmd` while the task still uses the old launch.

## Also seen, not fixed

- Leaderboard scores are sometimes misread by a digit ("979,700" between 279,800 and
  279,700; the speech log has 10 different scores for one player). Pre-existing.
- The pause menu re-announces the level summary when returning from the checkpoint list
  (it has the LEVEL title and a red bar, same as level select). Pre-existing, harmless.

## v1.0.1.1: default controls and Discord contact (docs only)

Later the same day. No narrator code changed.

- **README "Default controls"**: two Markdown tables (GitHub renders them as real HTML tables
  with header cells, so NVDA's table navigation works). "Buttons and keys" has columns
  Control / Keyboard / PlayStation / Xbox; "Moves" has Move / How to do it.
- **Where the bindings came from:**
  - Keyboard: the game's own Controls screen as the narrator spoke it (`logs/speech.log`,
    8 rows: ACTION, UP, LEFT, DOWN, RIGHT, QUICK RESTART, SELECT, RESTORE DEFAULTS) plus
    the 2026-09-27 notes. ACTION and SELECT = SPACE (OCR'd). The single letters (W, A, S,
    D, R) are known only from the 2026-09-27 investigation, since OCR can't speak them;
    which row R belongs to is inferred (QUICK RESTART), and the official manual confirms
    it. Enter = select and Escape = back come from the on-screen corner prompts.
  - Gamepad and moves: the official manual (https://thumpergame.com/manual/), which only
    names PlayStation buttons (Cross = action, left stick, L1 = Quick Restart). The Xbox
    column (A, LB) is the standard equivalent, our own mapping. Rings/bars "keep Action
    held" is from a Steam community guide.
  - **Not confirmed, deliberately not claimed:** whether the arrow keys work (the Controls
    screen shows an arrow icon beside each letter, and the README says only that); the
    gamepad's menu select/back and pause buttons (marked "Not documented" in the table).
- **Contact**: a README "Contact" section and INSTALL's "Still stuck?" now point to Discord,
  username `nion_light0972`. The GitHub issues link stays in INSTALL as a second option.
- **Version 1.0.1.1**: the user chose a four-part version. `Check-Update.ps1` compares with
  `[version]`, which treats 1.0.1.1 as newer than both 1.0.1 and 1.0.0; that code is
  unchanged since 1.0.0, so every installed copy is offered the update. Verified after
  publishing: a copy with `VERSION` 1.0.1 running `Check-Update.ps1` reported 1.0.1.1
  available with the right zip URL.
- WSL's `gh release view --json` has no `isLatest` field (old `gh`); the Check-Update run
  above is the better check that the new release is the latest anyway.
