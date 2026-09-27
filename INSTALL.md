# Installing

There is nothing to compile. This is a set of PowerShell scripts that run alongside the
game.

## 1. What you need first

- **Windows 10 or 11**
- **Thumper**, installed through Steam
- **NVDA**, running — this mod speaks through NVDA rather than providing its own voice

## 2. Get the files

```
git clone https://github.com/<your-user>/ThumperAccess.git
```

Or download the ZIP from GitHub and extract it anywhere you like. No install directory is
required and nothing is written into the game folder.

## 3. Add the NVDA Controller Client

**This is the one manual step, and the mod will not speak without it.**

The NVDA Controller Client is NV Access's library, not part of this project, so it is not
bundled here.

1. Download the **NVDA Controller Client** package from
   [nvaccess.org](https://www.nvaccess.org/) (it is published alongside NVDA, under
   "developer resources" / the controllerClient download).
2. Open it and find **`nvdaControllerClient32.dll`** — the **32-bit** one, in the `x86`
   folder. The 64-bit build will not work; see the note below.
3. Create a folder called `lib` in the root of this project and copy the DLL into it:

```
ThumperAccess\lib\nvdaControllerClient32.dll
```

If the DLL is missing, the narrator exits immediately and tells you exactly where to put
it.

### Why the 32-bit DLL

The launcher runs the narrator under 32-bit PowerShell. The controller client has to match
the architecture of the process calling it, and the 32-bit build works everywhere —
including on ARM64 Windows machines, where the 64-bit build cannot be loaded by the ARM64
PowerShell at all. This was developed on an ARM64 device for exactly that reason.

## 4. Run it

Start NVDA, start Thumper, then run:

```
tools\narrator\Start-Narrator.cmd
```

You should hear "Thumper narrator ready". Move through the menu and each item is spoken,
for example `PLAY, item 1 of 4`.

**Use the `.cmd`, not the `.ps1`.** PowerShell blocks unsigned scripts by default, so
running the `.ps1` directly fails with *"running scripts is disabled on this system"*. The
`.cmd` sets an execution-policy bypass for that single launch and changes nothing about
your machine's settings.

To stop it, press `Ctrl+C` in that window or just close the window. Launching it again
automatically replaces a running copy, so you can never end up with two voices at once.

## 5. (Optional) Start it automatically with the game

By default you run `Start-Narrator.cmd` yourself each time. To skip that:

```
tools\setup\Install-AutoStart.cmd
```

This is a one-time setup. From then on, the narrator starts on its own within a second or
two of Thumper launching — however you launch it, Steam or otherwise — and stops itself
when you close the game. Nothing to run by hand afterward.

To turn it back off, run `tools\setup\Uninstall-AutoStart.cmd`.

## Usage notes

- Everything spoken is logged with timestamps to `logs/speech.log`.
- The narrator stays silent during actual gameplay, by design.
- **Updates check themselves.** Each time the narrator starts, it checks whether a newer
  version has been released. If one has, it says so and tells you to press any `F1`-`F12`
  key to install it — that installs the update and restarts the narrator automatically.
  Nothing to download or run by hand. No internet, or no update available, is silent: the
  narrator just starts normally either way.

## Troubleshooting

**Nothing is spoken, but the window says it started.**
Check NVDA is actually running. The narrator speaks through NVDA and does nothing if it is
not there.

**"Cannot find nvdaControllerClient32.dll".**
Step 3 was missed, or the 64-bit DLL was copied instead of the 32-bit one. The file must be
named `nvdaControllerClient32.dll`.

**"Running scripts is disabled on this system".**
The `.ps1` was run directly. Use `tools\narrator\Start-Narrator.cmd`.

**Menu items are misread, or nothing is announced as you move.**
The reader locates Thumper's red selection bar on screen. A display scaling or colour
filter that changes how the game looks can interfere. Run
`tools\ocr\ReadSelection.ps1` to see what it reads for the currently selected row.

**Scores and ranks are wrong or missing, or you hear "Could not find the Thumper install
folder".**
Those come from Thumper's save file, not the screen. The narrator looks for your install
under every Steam library it can find automatically, which covers most setups. If it still
can't find it (a non-Steam copy, or an unusual install location):

1. Copy `config\game-dir.example.txt` to `config\game-dir.txt` in this same folder.
2. Edit `game-dir.txt` and replace the path with your own Thumper install folder — the one
   that directly contains `THUMPER_win8.exe`.
3. Restart the narrator.

`config\game-dir.txt` is specific to your machine, so it is not part of what you downloaded
and never gets committed if you contribute changes back.

`tools\savedata\ParseSave.ps1` prints what it finds if you want to check this directly.

## Uninstalling

If you set up auto-start (step 5), run `tools\setup\Uninstall-AutoStart.cmd` first —
otherwise a scheduled task is left behind, pointing at files that no longer exist. Then
delete the folder. Nothing else is installed system-wide, no registry keys are written, and
the game directory is never modified.
