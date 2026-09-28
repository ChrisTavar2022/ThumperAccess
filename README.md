# Thumper Access

A screen reader accessibility mod for the rhythm game **Thumper**. It reads the game's
menus, settings, level progress and section results aloud through the
[NVDA](https://www.nvaccess.org/) screen reader, so blind and low-vision players can find
their way around the game on their own.

- **Get Thumper:** [Thumper on Steam](https://store.steampowered.com/app/356400/Thumper/)
- **Get the mod:** [latest release](https://github.com/ChrisTavar2022/ThumperAccess/releases/latest)
- **Install guide:** [INSTALL.md](INSTALL.md)

## What is Thumper?

[Thumper](https://store.steampowered.com/app/356400/Thumper/) is a rhythm-action game by
Drool, released in 2016. Its developers call it "rhythm violence": you are a metal space
beetle hurtling down a track through a hellish void, hitting notes in time with a pounding
soundtrack while dodging hazards, on the way to a showdown with a giant head from the future.

How it plays:

- **Hit notes on the beat.** The core of the game is pressing in time with the music.
- **Steer and brace.** Turn into curves, jump over spikes, and hold steady through
  barriers instead of crashing into them.
- **One hit of shield.** A hit knocks your shield away; a second hit before it returns
  sends you back to the last checkpoint.
- **Scored sections.** Each of the nine levels is split into sections, and each section
  gets a rank from D up to S. Finishing a level unlocks **Play+**, a harder replay.
- **Simple controls.** One direction stick and one button, on keyboard or controller.
  The mod reads the Controls screen aloud if you want to check or change the keys.

Thumper's gameplay is driven by sound and rhythm, which makes it very playable by ear.
Its menus, though, are pictures drawn on screen with nothing a screen reader can read. That
is the gap this mod fills.

More about the game: [official site](https://thumpergame.com/) and
[Wikipedia](https://en.wikipedia.org/wiki/Thumper_(video_game)).

## What the mod reads aloud

- **Every menu:** the main menu, Options, Gameplay, Controls, Audio, Video, Credits, the
  pause menu, and Yes/No dialogs. Each row says where it is in the list:
  "PLAY, item 1 of 4".
- **Settings values:** "FULLSCREEN, ON", "FRAME RATE, VSYNC", and sliders:
  "VOLUME slider set to 3, range 1 to 12".
- **Level select:** your best score, rank, S-rank count, and how far through the level
  your current run is: "Level 1, best score 115,250, rank A, 8 S ranks. current run 6 of
  15 sections".
- **Section results, as you play:** the moment you finish a section, just the rank
  letter you earned, such as "S" or "A". Nothing longer is spoken during play, so it never
  distracts from the music. Full scores are on the level select screen.
- **Restart from checkpoint:** each checkpoint with how you did on that section:
  "Level 1, checkpoint 6, rank S, 6,000 points" or "checkpoint 7, not played yet".
- **Leaderboards:** the level, then each row: "rank 11, SINTHREX, 279,300".

Scores and ranks come straight from the game's save file, so they are always exact.

The mod never presses keys or plays for you. It only reads the screen and speaks, and your
controls work exactly as they normally do.

## Quick start

You need Windows 10 or 11, Thumper from Steam, and NVDA. The mod speaks through NVDA only,
so other screen readers such as JAWS or Windows Narrator are not supported.

1. Download the ZIP from the
   [latest release](https://github.com/ChrisTavar2022/ThumperAccess/releases/latest)
   and extract it anywhere, for example to your Documents folder.
2. Download the NVDA Controller Client from
   [download.nvaccess.org/releases/stable](https://download.nvaccess.org/releases/stable/).
   It is the file ending in `_controllerClient.zip`.
3. From that ZIP, copy `x86\nvdaControllerClient.dll` into a new folder named `lib`
   inside the mod's folder.
4. Start NVDA and Thumper, then run `tools\narrator\Start-Narrator.cmd`. You will hear
   "Thumper narrator ready".
5. Optional: run `tools\setup\Install-AutoStart.cmd` once, and the mod will start and stop
   with the game from then on.

[INSTALL.md](INSTALL.md) walks through every step in detail and covers troubleshooting,
updating and uninstalling. Updates install themselves: when a new version is out, the mod
tells you on startup and installs it at the press of a key.

## Known limitations

- **Single-letter key bindings aren't spoken.** On the Controls screen, keys like W, A, S,
  D and R can't be read, a limit of Windows' text recognition with lone letters. Longer
  names such as SPACE are read normally.
- **Leaderboards:** the small rank badge next to each row isn't read yet, and on very fast
  paging the level title is occasionally skipped.
- **No gameplay assistance.** During play, the mod only announces section results. It
  doesn't describe the track or upcoming obstacles.

## How it works

Thumper draws its own interface, so there is nothing for a screen reader to hook into. The
mod works like a sighted player: it takes a screenshot several times a second, finds the
red highlight bar (or gold outline) that marks the selected item, reads that part of the
screen with the text recognition built into Windows, and sends the words to NVDA. Sliders
are measured rather than read. Scores and ranks are taken from Thumper's save file, which
isn't encrypted, rather than read off the screen.

Everything is plain PowerShell. There is nothing to compile, nothing is installed
system-wide, and the game's files are never modified.

<!-- dist:exclude -->
## For contributors

- `tools/narrator/`: the narrator itself (`ThumperNarrator.ps1`) and its launcher
- `tools/savedata/ParseSave.ps1`: decodes the save file (levels, scores, section ranks)
- `tools/setup/`, `tools/updater/`: auto-start, the release packager, self-updating
- `tools/input/SendKey.ps1`: injects key presses, for driving the game while testing
- `tools/capture/`, `tools/ocr/`: screenshot and one-shot OCR diagnostics
- `tools/ghidra_scripts/`, `tools/scan/`: reverse-engineering tooling, kept for future
  gameplay-assist work
- `notes/`: dated session notes, including dead ends and why they were abandoned
- `project_status.md`: current state and next steps

Read `notes/session-2026-09-18-screen-reading-breakthrough.md` before changing the
narrator. It records the traps that cost real time: DPI scaling silently shrinking
screenshots, an always-animated background defeating naive change detection, and icon
glyphs next to a value breaking OCR.

Build a player package with `tools\setup\Build-Release.ps1`, which writes
`dist\ThumperAccess\`.
<!-- /dist:exclude -->

## License

MIT. See [LICENSE](LICENSE).

## Credits

Thumper is made by [Drool](https://drool.ws/). This is an unofficial, fan-made
accessibility mod, not affiliated with or endorsed by Drool, and it includes no game files.

The NVDA Controller Client is made by [NV Access](https://www.nvaccess.org/) and is
downloaded separately.
