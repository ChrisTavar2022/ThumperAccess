<#
Check-Update.ps1 - checks GitHub Releases for a version newer than the one installed.

Prints one line of JSON: { "Available": bool, "Version": "x.y.z", "Url": "..." }

Never throws. No internet, GitHub being down, or no release ever having been published are
all ordinary conditions for a player, not errors - the narrator must keep working exactly
as before if this fails, so every failure just reports Available=false.
#>
param(
    [string]$Repo = "ChrisTavar2022/ThumperAccess"
)

function Write-Result([bool]$available, [string]$version = "", [string]$url = "") {
    [pscustomobject]@{ Available = $available; Version = $version; Url = $url } |
        ConvertTo-Json -Compress
}

try {
    $versionFile = Join-Path $PSScriptRoot "..\..\VERSION"
    $current = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { "0.0.0" }

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
        -Headers @{ "User-Agent" = "ThumperAccess-Updater" } -TimeoutSec 5 -ErrorAction Stop

    $latest = $release.tag_name.TrimStart('v', 'V')
    $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $asset) { Write-Result $false; return }

    if ([version]$latest -gt [version]$current) {
        Write-Result $true $latest $asset.browser_download_url
    } else {
        Write-Result $false
    }
} catch {
    Write-Result $false
}
