<#
Speak.ps1 - send text to NVDA via the NVDA Controller Client.

ARCHITECTURE NOTE: this host is Windows on ARM64. The controller client DLL must match
the calling process, and we only ship x86/x64 clients (tools/tolk/libs). ARM64 PowerShell
can load neither, so this script is meant to run under the 32-bit PowerShell in SysWOW64,
which Windows on ARM emulates. Use Say.ps1 as the entry point - it re-launches this
script under the right host automatically.

Usage (via Say.ps1):
  .\Say.ps1 "Leaderboards"
  .\Say.ps1 "Leaderboards" -Interrupt
#>
param(
    [Parameter(Mandatory = $true)][string]$Text,
    [switch]$Interrupt
)

$dll = Join-Path $PSScriptRoot "..\tolk\libs\x86\nvdaControllerClient32.dll"
$dll = (Resolve-Path $dll).Path

$sig = @"
using System;
using System.Runtime.InteropServices;
public class Nvda {
    [DllImport(@"$dll", CharSet = CharSet.Unicode)] public static extern int nvdaController_testIfRunning();
    [DllImport(@"$dll", CharSet = CharSet.Unicode)] public static extern int nvdaController_speakText(string text);
    [DllImport(@"$dll", CharSet = CharSet.Unicode)] public static extern int nvdaController_cancelSpeech();
}
"@
if (-not ("Nvda" -as [type])) { Add-Type -TypeDefinition $sig }

$running = [Nvda]::nvdaController_testIfRunning()
if ($running -ne 0) {
    Write-Output "NVDA=not_running (code $running)"
    exit 1
}

if ($Interrupt) { [void][Nvda]::nvdaController_cancelSpeech() }
$rc = [Nvda]::nvdaController_speakText($Text)
Write-Output "SPOKE=$rc : $Text"
