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
    Copy-Item $src $dst
}

# The player drops their own NVDA controller client here (see INSTALL.md step 3) - create
# the folder so that is the only thing left to do, not "first make a folder, then...".
New-Item -ItemType Directory -Path (Join-Path $OutDir "lib") -Force | Out-Null

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
    Compress-Archive -Path "$OutDir\*" -DestinationPath $zipPath
    Write-Host ""
    Write-Host "Zipped: $zipPath"
}
