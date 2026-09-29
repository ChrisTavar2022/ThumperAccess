# Installing Thumper Access

This guide takes you from nothing to hearing Thumper's menus spoken, in about ten minutes.
There is nothing to compile and no installer: the mod is a folder of scripts that runs
alongside the game.

## 1. What you need

- **Windows 10 or 11**
- **Thumper**, from [Steam](https://store.steampowered.com/app/356400/Thumper/)
- **NVDA**, from [nvaccess.org](https://www.nvaccess.org/download/). The mod speaks
  through NVDA only. JAWS, Narrator and other screen readers are not supported.

## 2. Download the mod

1. Go to the
   [latest release](https://github.com/ChrisTavar2022/ThumperAccess/releases/latest) page.
2. Under "Assets", download **`ThumperAccess.zip`**.
3. **Unblock the ZIP before extracting it.** Windows marks files downloaded from the
   internet, and without this step it can show a security prompt every time you run one of
   the mod's `.cmd` files. In File Explorer, select the ZIP and press `Alt+Enter` to open
   its Properties. On the General tab, check the **Unblock** checkbox near the bottom,
   then press Enter. If there is no Unblock checkbox, the file is already unblocked.
4. Extract the ZIP anywhere you like, for example your Documents folder. With the ZIP
   selected, press the Applications key (or `Shift+F10`), choose **Extract All**, and
   accept the suggested destination. Extract All puts everything in a new folder named
   after the ZIP, and inside that is the mod's own **`ThumperAccess`** folder. That inner
   folder is the one the rest of this guide means by "your `ThumperAccess` folder".

Nothing goes into the game's own folder, and the game's files are never changed.

## 3. Add the NVDA Controller Client

**This is the one manual step, and the mod can't speak without it.**

The NVDA Controller Client is a small file from NV Access that lets other programs speak
through NVDA. It belongs to NV Access, so it can't be included in this download.

1. Go to [download.nvaccess.org/releases/stable](https://download.nvaccess.org/releases/stable/).
2. Download the file whose name ends in **`_controllerClient.zip`**, for example
   `nvda_2026.2_controllerClient.zip`.
3. Open that ZIP. It has four folders: `arm64`, `arm64ec`, `x64` and `x86`.
4. Open the **`x86`** folder and copy **`nvdaControllerClient.dll`**. It must be the one
   from `x86`, even on a 64-bit or ARM computer (see the note below).
5. In your `ThumperAccess` folder, open the **`lib`** folder and paste the file there. The
   `lib` folder comes with the mod and holds a short note reminding you of this step. The
   file should end up here:

```
ThumperAccess\lib\nvdaControllerClient.dll
```

If the file is missing, or is from the wrong folder, the narrator tells you so when it
starts, and exits.

**Why x86?** The narrator runs as a 32-bit program so that it works the same way on every
Windows computer, including ARM ones, and a 32-bit program can only load the 32-bit (x86)
file. An older copy named `nvdaControllerClient32.dll` also works.

## 4. Run it

1. Start NVDA.
2. Start Thumper.
3. In the `ThumperAccess` folder, open `tools`, then `narrator`, and run
   **`Start-Narrator.cmd`**.

You should hear "Thumper narrator ready". Move through the menu with the arrow keys and
each item is spoken, for example "PLAY, item 1 of 4".

To stop it, close the narrator window or press `Ctrl+C` in it. Starting it again replaces a
copy that is already running, so you never get two voices at once.

**Run the `.cmd` file, not the `.ps1`.** Windows blocks PowerShell scripts by default, so
opening `ThumperNarrator.ps1` directly fails with "running scripts is disabled on this
system". The `.cmd` allows the script for that one launch only, and changes no settings on
your computer.

## 5. Optional: start it automatically with the game

Instead of running `Start-Narrator.cmd` every time, you can have it start by itself.
Run this once:

```
tools\setup\Install-AutoStart.cmd
```

From then on, whenever you sign in to Windows, a small background watcher waits for
Thumper. The narrator starts a second or two after the game does, however you launch it,
and stops when you close the game. No administrator rights are needed.

To turn this off again, run `tools\setup\Uninstall-AutoStart.cmd`.

If you later move or rename the `ThumperAccess` folder, run `Install-AutoStart.cmd` again
from its new location, since auto-start remembers where the folder was.

If you turned on auto-start with version 1.0.0, run `Install-AutoStart.cmd` once more after
updating. On Windows 11 the 1.0.0 version could open a terminal window when you signed in,
and closing that window stopped auto-start until the next sign-in. The narrator reminds you
at startup until this is done.

## Updates

Each time the narrator starts, it checks for a newer release. If there is one, it tells
you, and pressing any function key from `F1` to `F12` while Thumper is the active window
downloads and installs it, then restarts the narrator. Your `lib` folder and settings are kept. With no internet
connection, or no update available, it just starts normally.

## Good to know

- **During gameplay** the mod stays quiet except for one thing: when you finish a section,
  it says the rank you earned, just the letter, such as "S" or "A". Your points and
  totals are read on the level select screen instead, outside of play.
- **The mod never presses keys.** It only reads the screen, so your controls behave exactly
  as normal.
- **Everything spoken is written to a log**, `logs\speech.log`, with the time. If
  something sounds wrong, that log shows exactly what was said and when, which helps a lot
  when reporting a problem.

## Troubleshooting

**The narrator window opens, but nothing is spoken.**
Make sure NVDA is running. The mod speaks through NVDA and is silent without it.

**"Cannot find the NVDA Controller Client".**
Step 3 was missed, or the file is in the wrong place. It must be
`ThumperAccess\lib\nvdaControllerClient.dll`: in a folder named `lib`, directly inside the
`ThumperAccess` folder.

**"...is not the 32-bit (x86) version of the NVDA Controller Client".**
The file was copied from the `x64`, `arm64` or `arm64ec` folder. Replace it with the one
from the `x86` folder.

**"Running scripts is disabled on this system".**
The `.ps1` file was opened directly. Run `tools\narrator\Start-Narrator.cmd` instead.

**Menu items are misread, or nothing is announced when you move.**
The mod finds Thumper's red highlight bar on screen. Anything that changes how the game
looks can get in the way, such as Windows colour filters, high contrast mode, or a
magnifier zoomed over the game. Running the game fullscreen gives the best results.

**Scores and ranks are missing, or you hear "Could not find the Thumper install folder".**
Scores and ranks come from Thumper's save file, which the mod finds by looking through
all of your Steam library folders. If your copy of Thumper is somewhere unusual:

1. In the `ThumperAccess\config` folder, copy `game-dir.example.txt` and name the copy
   `game-dir.txt`.
2. Open `game-dir.txt` and replace the example path with your own Thumper folder, the one
   that contains `THUMPER_win8.exe`.
3. Restart the narrator.

**Still stuck?** Open an issue on the
[project's GitHub page](https://github.com/ChrisTavar2022/ThumperAccess/issues), describe
what happened, and include the end of `logs\speech.log` if you can.

## Uninstalling

1. If you turned on auto-start (step 5), run `tools\setup\Uninstall-AutoStart.cmd` first.
   Otherwise a Windows scheduled task is left behind, pointing at files that no longer
   exist.
2. Delete the `ThumperAccess` folder.

That's everything. The mod writes no registry keys, installs nothing system-wide, and never
touches the game's folder.
