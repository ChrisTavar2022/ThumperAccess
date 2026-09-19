# Thumper Accessibility Mod

Makes [Thumper](https://thumpergame.com/) playable without sight by speaking its menus
through [NVDA](https://www.nvaccess.org/).

Thumper is a rhythm game whose gameplay is already almost entirely audio-driven — but its
menus, settings and rank screens are drawn as pixels with no accessibility information at
all. This project reads those screens and speaks them.

## Status

Working:

- Main menu, Options, Audio, Video, pause menu, Yes/No dialogs, section start screen
- Level select: level, best score, overall rank, S-rank count, current-run progress
- Settings values: toggles (`FULLSCREEN, ON`), text values (`FRAME RATE, VSYNC`), and
  pip sliders (`VOLUME slider set to 3, range 1 to 12`)
- Menu position on every row (`PLAY, item 1 of 4`), with locked entries excluded
- `F8` on the level select reads section-by-section best ranks

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

## License

MIT — see [LICENSE](LICENSE).

## Credits

Thumper is by [Drool](https://drool.ws/). This project is an unofficial, third-party
accessibility layer and ships no game assets.
