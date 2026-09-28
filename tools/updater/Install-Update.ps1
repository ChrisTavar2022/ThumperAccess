<#
Install-Update.ps1 - downloads a release zip and extracts it over the current install.

Only ever touches the files Build-Release.ps1 packages (see its own file list) - the
release zip never contains lib\ contents or config\game-dir.txt, so this can never
overwrite the player's own NVDA controller client or their game-folder override.
Copying the unpacked release over the install overwrites the files the release contains and
leaves everything else in place, which is exactly that: a merge, not a wipe-and-replace.

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
$tmpDir = Join-Path $env:TEMP "ThumperAccess-update"

# GitHub only accepts TLS 1.2+, which older .NET defaults in Windows PowerShell 5.1 do not
# always enable - without this the download can fail on an otherwise working machine.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try {
    Invoke-WebRequest -Uri $Url -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
    # Unpack to a scratch folder first, then copy over the install. The release zip holds
    # a single top-level ThumperAccess\ folder (so players' extract tools make one tidy
    # folder); unpacking straight into $root would nest a second copy inside it.
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $src = $tmpDir
    $inner = @(Get-ChildItem $tmpDir)
    if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $src = $inner[0].FullName }
    if (-not (Test-Path (Join-Path $src "VERSION"))) { throw "Downloaded update is not a ThumperAccess release." }
    Copy-Item -Path (Join-Path $src "*") -Destination $root -Recurse -Force
} finally {
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
