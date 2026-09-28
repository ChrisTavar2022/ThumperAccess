<#
Build-Release.ps1 - assembles a clean, player-only copy of the mod: just what
Start-Narrator.cmd (and the optional auto-start) actually need at runtime, none of the
Ghidra/notes/scan dev material a player has no reason to see or download.

The explicit file list below IS the source of truth for "what a player needs" - if a
runtime script starts depending on a new file, add it here too, or the packaged copy will
silently fail to find it despite working fine from the full dev repo.

Usage:
  .\Build-Release.ps1              # writes dist\ThumperAccess\ next to the repo root
  .\Build-Release.ps1 -Zip         # also produces dist\ThumperAccess.zip
#>
param(
    [string]$OutDir = "",
    [switch]$Zip
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "dist\ThumperAccess" }

# Everything a player's copy needs to run - and nothing else.
$files = @(
    "tools\narrator\ThumperNarrator.ps1",
    "tools\narrator\Start-Narrator.cmd",
    "tools\narrator\Watch-Thumper.ps1",
    "tools\savedata\ParseSave.ps1",
    "tools\setup\Install-AutoStart.ps1",
    "tools\setup\Install-AutoStart.cmd",
    "tools\setup\Uninstall-AutoStart.ps1",
    "tools\setup\Uninstall-AutoStart.cmd",
    "tools\updater\Check-Update.ps1",
    "tools\updater\Install-Update.ps1",
    "config\game-dir.example.txt",
    "INSTALL.md",
    "LICENSE",
    "VERSION"
)

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

foreach ($f in $files) {
    $src = Join-Path $repoRoot $f
    if (-not (Test-Path $src)) { throw "Build-Release.ps1's file list is out of date - missing: $f" }
    $dst = Join-Path $OutDir $f
    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
    if ($f -like '*.cmd') {
        # cmd.exe misparses batch files with bare-LF line endings. .gitattributes asks for
        # CRLF, but a file written from WSL or by a tool can still sit on disk as LF (two
        # launchers did on 2026-09-28), and this package is built from the working copy.
        $text = [System.IO.File]::ReadAllText($src) -replace "`r?`n", "`r`n"
        [System.IO.File]::WriteAllText($dst, $text, (New-Object System.Text.ASCIIEncoding))
    } else {
        Copy-Item $src $dst
    }
}

# The player drops their own NVDA controller client here (see INSTALL.md step 3) - ship
# the folder so that is the only thing left to do, not "first make a folder, then...". It
# needs a file in it: Compress-Archive silently drops empty folders, so an empty lib\ would
# never reach the player. The updater merging this note over an install is harmless - it
# never overwrites the DLL itself.
$libDir = Join-Path $OutDir "lib"
New-Item -ItemType Directory -Path $libDir -Force | Out-Null
Set-Content -Path (Join-Path $libDir "PUT-NVDA-DLL-HERE.txt") -Encoding ASCII -Value @(
    "Put nvdaControllerClient.dll in this folder.",
    "",
    "Get it from https://download.nvaccess.org/releases/stable/ - download the file ending",
    "in _controllerClient.zip, open it, and copy nvdaControllerClient.dll from its x86",
    "folder into this lib folder. See INSTALL.md, step 3."
)

# README.md is mostly player-facing already, but its "Layout" and "Notes for contributors"
# sections describe dev-only files (notes/, tools/ocr, project_status.md, ...) that are not
# in this package and would only confuse a player - strip anything between the dist:exclude
# markers rather than hand-maintaining a second copy of the file.
$readme = Get-Content (Join-Path $repoRoot "README.md") -Raw
$readme = $readme -replace '(?s)<!-- dist:exclude -->.*?<!-- /dist:exclude -->\r?\n?', ''
Set-Content -Path (Join-Path $OutDir "README.md") -Value $readme -NoNewline

Write-Host "Packaged player release at $OutDir"
Write-Host ""
Get-ChildItem $OutDir -Recurse -File | ForEach-Object {
    Write-Host ("  " + $_.FullName.Substring($OutDir.Length + 1))
}

if ($Zip) {
    $zipPath = "$OutDir.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    # The folder itself, not its contents: the zip then holds a single ThumperAccess\ folder,
    # so every extract tool (Windows "Extract All", 7-Zip "Extract here", ...) produces the
    # same tidy folder instead of scattering files. Install-Update.ps1 expects this layout.
    # Entries are added one by one with explicit "/" names: under Windows PowerShell 5.1 both
    # Compress-Archive and ZipFile.CreateFromDirectory write backslash separators, which some
    # extract tools turn into files literally named "ThumperAccess\tools\...".
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $top = Split-Path $OutDir -Leaf
    $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem $OutDir -Recurse -File | ForEach-Object {
            $name = "$top/" + $_.FullName.Substring($OutDir.Length + 1).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $name,
                [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $archive.Dispose()
    }
    Write-Host ""
    Write-Host "Zipped: $zipPath"
}
