<#
Install-Update.ps1 - downloads a release zip and extracts it over the current install.

Only ever touches the files Build-Release.ps1 packages (see its own file list) - the
release zip never contains lib\ contents or config\game-dir.txt, so this can never
overwrite the player's own NVDA controller client or their game-folder override.
Expand-Archive -Force overwrites files the archive contains and leaves everything else in
place, which is exactly that: a merge, not a wipe-and-replace.

Deliberately does not call `exit`: the narrator invokes this in-process with `&` while it
is still running, and `exit` inside a called script terminates that whole host process, not
just this one - which would take the narrator down on a failed update instead of letting it
carry on with the version already installed. A failure is a normal terminating error
instead, which the caller can catch without dying.
#>
param(
    [Parameter(Mandatory = $true)][string]$Url
)

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$tmpZip = Join-Path $env:TEMP "ThumperAccess-update.zip"

try {
    Invoke-WebRequest -Uri $Url -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path $tmpZip -DestinationPath $root -Force
} finally {
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
}
