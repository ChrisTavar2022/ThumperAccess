<#
Capture.ps1 - screen/window capture for observing Thumper while Claude drives analysis.

Usage:
  .\Capture.ps1                       # full virtual screen
  .\Capture.ps1 -Window THUMPER_win8  # just the Thumper window (by process name)
  .\Capture.ps1 -Name menu_main       # custom file name stem
  .\Capture.ps1 -MaxWidth 1600        # downscale cap (default 1280, 0 = no resize)

Writes PNG to <project>\captures\ and prints the full path.
#>
param(
    [string]$Window = "",
    [string]$Name = "",
    [int]$MaxWidth = 1280,
    [int]$DelaySeconds = 0,
    [int]$KeepLast = 12
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$sig = @'
using System;
using System.Runtime.InteropServices;
public class WinCap {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr hWnd, [Out] char[] s, int n);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
if (-not ("WinCap" -as [type])) { Add-Type -TypeDefinition $sig }

# Without this the grab is a downscaled, DPI-virtualized view of the desktop, not real pixels.
[void][WinCap]::SetProcessDPIAware()

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

$outDir = Join-Path $PSScriptRoot "..\..\captures"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outDir = (Resolve-Path $outDir).Path

$stem = if ($Name) { $Name } else { "cap" }
$file = Join-Path $outDir ("{0}_{1}.png" -f $stem, (Get-Date -Format "HHmmss"))

# Determine capture rectangle
if ($Window) {
    $proc = Get-Process -Name $Window -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) { Write-Error "No window found for process '$Window'"; exit 1 }
    $r = New-Object WinCap+RECT
    [void][WinCap]::GetWindowRect($proc.MainWindowHandle, [ref]$r)
    $x = $r.Left; $y = $r.Top; $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
} else {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $x = $vs.X; $y = $vs.Y; $w = $vs.Width; $h = $vs.Height
}

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$g.Dispose()

# Report mean brightness so a black (exclusive-fullscreen DX) grab is detectable without eyes
$probe = New-Object System.Drawing.Bitmap($bmp, (New-Object System.Drawing.Size(32, 32)))
$sum = 0.0
for ($py = 0; $py -lt 32; $py++) { for ($px = 0; $px -lt 32; $px++) { $sum += $probe.GetPixel($px, $py).GetBrightness() } }
$probe.Dispose()
$meanBrightness = [math]::Round($sum / 1024, 4)

if ($MaxWidth -gt 0 -and $w -gt $MaxWidth) {
    $nh = [int]($h * $MaxWidth / $w)
    $small = New-Object System.Drawing.Bitmap($MaxWidth, $nh)
    $sg = [System.Drawing.Graphics]::FromImage($small)
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $sg.DrawImage($bmp, 0, 0, $MaxWidth, $nh)
    $sg.Dispose(); $bmp.Dispose(); $bmp = $small
}

$bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

# Captures are disposable working files - keep only the most recent few.
Get-ChildItem $outDir -Filter *.png |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $KeepLast |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Output "FILE=$file"
Write-Output "SRC_RECT=${x},${y} ${w}x${h}"
Write-Output "MEAN_BRIGHTNESS=$meanBrightness"
