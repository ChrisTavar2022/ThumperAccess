# Speech.ps1 - NVDA speech and the speech log. Dot-sourced by ThumperNarrator.ps1, which
# defines $RepoRoot and $Quiet. Stops the narrator at startup if the NVDA controller client
# is missing or the wrong build - nothing else can work without it.

# The NVDA controller client is NOT bundled - it is NV Access's DLL, not ours to
# redistribute - so look for wherever the user put it. See INSTALL.md.
# Current NVDA packages ship the 32-bit client as x86\nvdaControllerClient.dll; older ones
# named it nvdaControllerClient32.dll. Accept either.
$libDir = Join-Path $RepoRoot "lib"
$dllCandidates = @(
    (Join-Path $libDir "nvdaControllerClient.dll"),
    (Join-Path $libDir "nvdaControllerClient32.dll")
)
$nvdaDll = $null
foreach ($c in $dllCandidates) {
    if (Test-Path $c) { $nvdaDll = (Resolve-Path $c).Path; break }
}
if (-not $nvdaDll) {
    Write-Host ""
    Write-Host "Cannot find the NVDA Controller Client - speech is not available."
    Write-Host "Download it from https://download.nvaccess.org/releases/stable/ (the file"
    Write-Host "ending in _controllerClient.zip), and copy x86\nvdaControllerClient.dll into:"
    Write-Host ("  " + $libDir)
    Write-Host "See INSTALL.md for the full steps."
    exit 1
}
# The package also contains x64, arm64 and arm64ec builds under the same file name, and
# copying the wrong one only fails later as a cryptic "bad image format" error. The PE
# header's machine field says which one it is: 0x14c is 32-bit x86.
$peBytes = [System.IO.File]::ReadAllBytes($nvdaDll)
$machine = [BitConverter]::ToUInt16($peBytes, [BitConverter]::ToInt32($peBytes, 0x3C) + 4)
if ($machine -ne 0x14c) {
    Write-Host ""
    Write-Host "$nvdaDll is not the 32-bit (x86) version of the NVDA Controller Client."
    Write-Host "Replace it with the one from the x86 folder of the download. See INSTALL.md."
    exit 1
}
$nsig = @"
using System;
using System.Runtime.InteropServices;
public class Nvda {
    [DllImport(@"$nvdaDll", CharSet = CharSet.Unicode)] public static extern int nvdaController_testIfRunning();
    [DllImport(@"$nvdaDll", CharSet = CharSet.Unicode)] public static extern int nvdaController_speakText(string text);
    [DllImport(@"$nvdaDll", CharSet = CharSet.Unicode)] public static extern int nvdaController_cancelSpeech();
}
"@
if (-not ("Nvda" -as [type])) { Add-Type -TypeDefinition $nsig }

# Everything spoken is appended here, so the whole history of what the game announced can
# be reviewed later while building the rest of the mod.
$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogPath = Join-Path ((Resolve-Path $logDir).Path) "speech.log"
Add-Content -Path $LogPath -Encoding UTF8 -Value ("=== narrator started {0} ===" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

function Write-SpeechLog([string]$text) {
    try {
        Add-Content -Path $LogPath -Encoding UTF8 -Value ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $text)
    } catch {
        # Never let logging take the narrator down mid-session.
    }
}

# -Queue speaks after whatever is still being said instead of cutting it off.
function Say([string]$text, [switch]$Queue) {
    Write-SpeechLog $text
    if ($Quiet) { Write-Host "[would speak] $text"; return }
    if (-not $Queue) { [void][Nvda]::nvdaController_cancelSpeech() }
    [void][Nvda]::nvdaController_speakText($text)
}
