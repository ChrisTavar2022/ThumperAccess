# Thumper Accessibility Mod

Makes [Thumper](https://thumpergame.com/) playable without sight by speaking its menus
through [NVDA](https://www.nvaccess.org/).

Thumper is a rhythm game whose gameplay is already almost entirely audio-driven — but its
menus, settings and rank screens are drawn as pixels with no accessibility information at
all. This project reads those screens and speaks them.

## Status

Working:

- Main menu, Options, Gameplay, Audio, Video, Leaderboards, pause menu, Yes/No dialogs,
  section start screen, Credits
- Level select: level, best score, overall rank, S-rank count, current-run progress
- Settings values: toggles (`FULLSCREEN, ON`), text values (`FRAME RATE, VSYNC`), and
  pip sliders (`VOLUME slider set to 3, range 1 to 12`)
- Menu position on every row (`PLAY, item 1 of 4`), with locked entries excluded
- Controls screen: reads every row and its correct position, and speaks multi-letter key
  bindings (`SPACE`). Single-letter bindings (W, A, S, D, R) aren't spoken - a confirmed
  Windows OCR limitation with isolated single characters, not a guess or a wrong answer;
  open **Options → Controls** in-game to see those directly.
- "Restart from checkpoint?" (from RESTART mid-run): reads each checkpoint as you scroll
  (`"Level 1, checkpoint 14"`, or `"Level 1, current checkpoint"` for your most recent
  position), plus that level's current-run section ranks once per level.

Not done yet:

- The results screen shown after finishing a section
- Any assistance during gameplay itself

## How it works

Thumper renders its own UI with SDL2. There is no UI Automation tree, no control handles —
nothing for a screen reader to query. Reverse engineering the game binary to find menu
state was attempted across several sessions and did not pan out (see `notes/`).

So this reads the screen instead:

1. **Find the selection.** Thumper marks the selected row with a full-width bright red
   bar. That bar is a global UI convention, so one detector covers every menu.
2. **Split the row.** Settings rows are label-on-left, value-on-right separated by a wide
   gap. Each side is read separately — Windows OCR silently drops an isolated short value
   like `ON` when the whole row is read at once.
3. **Measure, don't read, widgets.** Volume-style sliders are a row of pips. OCR turns the
   hollow ones into `0000000000`, so they are counted geometrically instead.
4. **Count the rows** to derive "item N of M".
5. **Speak** via the NVDA controller client.

Scores and ranks are *not* OCR'd. Thumper's save file is unencrypted and contains them as
plain text, so they are read directly — exact, and it covers rank letters far too small to
OCR reliably.

## Requirements

- Windows, with Thumper installed via Steam
- NVDA running
- No build step — everything is PowerShell

## Learning Thumper

New to Thumper, or new to rhythm-action games generally? Thumper describes itself as
"rhythm violence": you play a metal space beetle racing down a track, hitting rhythm
prompts in time with the music while steering around hazards. Pulled from the developer's
own site and Steam listing:

- **Hit notes in time with the music** — the core rhythm-action, timed to the beat.
- **Steer** around curved sections of track, **jump** over spikes, and **brace** against
  certain obstacles instead of hitting them.
- Your beetle carries a shield that absorbs **one hit** — a second hit before it recharges
  ends the run, sending you back to the last checkpoint.
- Each level is split into scored sections, rated after you clear each one (this mod reads
  those ratings aloud — see "Level select" under Status above).
- Levels get progressively more rhythmically complex — each is built on a different musical
  time signature. Finishing a level unlocks **Play+**, a harder single-life replay.

**Controls:** Steam's own listing describes Thumper as using "one stick and one button,"
and recommends a controller, though keyboard works too — this mod has driven the game via
keyboard throughout its own testing. Exact key bindings aren't reproduced here since they
can be changed and a stale copy would be worse than none: the most reliable source is the
game itself. Open **Options → Controls** in-game and the narrator reads it aloud, the same
as any other settings screen.

**For a fuller sense of the game before diving in:**

- [Official site](https://thumpergame.com/)
- [Steam store page](https://store.steampowered.com/app/356400/) — listing, requirements,
  and the developer's own description of the controls
- [Wikipedia: Thumper (video game)](https://en.wikipedia.org/wiki/Thumper_(video_game)) —
  a fuller written overview of how the game plays

## Usage

```
tools\narrator\Start-Narrator.cmd
```

Use the `.cmd`, not the `.ps1`: PowerShell's default execution policy blocks unsigned
scripts, and the launcher sets bypass for that one launch only, changing no machine
settings. It also selects 32-bit PowerShell, required because the bundled NVDA controller
client is x86.

Stop with `Ctrl+C` or by closing the window. Starting it again replaces any running
instance. Everything spoken is appended to `logs/speech.log`.

**Optional: start it automatically.** Run `tools\setup\Install-AutoStart.cmd` once, and
the narrator starts itself whenever Thumper is running, and stops when you close it — no
need to launch it by hand each time. See `INSTALL.md` for details.

<!-- dist:exclude -->
## Layout

- `tools/narrator/` — the narrator
- `tools/savedata/ParseSave.ps1` — decodes the save file (levels, scores, ranks)
- `tools/input/SendKey.ps1` — scan-code key injection, for driving the game in testing
- `tools/capture/Capture.ps1` — screenshots the fullscreen game
- `tools/ocr/` — one-shot diagnostic readers
- `notes/` — session notes, including dead ends and why they were abandoned
- `project_status.md` — current state and next steps

## Notes for contributors

`notes/session-2026-09-18-screen-reading-breakthrough.md` documents the non-obvious traps
that cost real time, including DPI virtualisation silently downscaling captures, why
hashing pixels to detect change never fires (the background is always animating), and why
arrow glyphs beside a value break OCR entirely. Worth reading before changing the narrator.
<!-- /dist:exclude -->

## License

MIT — see [LICENSE](LICENSE).

## Credits

Thumper is by [Drool](https://drool.ws/). This project is an unofficial, third-party
accessibility layer and ships no game assets.
