<#
ReadSelection.ps1 - read Thumper's currently-selected menu item off the screen.

Thumper highlights the selected menu entry with a full-width, bright saturated red bar
and white text. That bar is far easier to find than the text: locate the bar rows, crop
to them, binarize white-on-red into black-on-white, upscale, then run Windows OCR.

Usage:
  .\ReadSelection.ps1                 # detect bar, OCR it, print text
  .\ReadSelection.ps1 -SaveDebug      # also keep the cropped strip for inspection
#>
param(
    [switch]$SaveDebug,
    [int]$Upscale = 3,
    [int]$XStart = 0,
    [int]$XEnd = 0
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class ThumperShot {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    // Returns the full-resolution screen grab.
    public static Bitmap Grab(int x, int y, int w, int h) {
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
        return bmp;
    }

    // Find contiguous rows that look like the highlight bar: mostly bright saturated red.
    // Returns {top, bottom} or {-1,-1}.
    public static int[] FindBar(Bitmap bmp) {
        int w = bmp.Width, h = bmp.Height;
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] buf = new byte[d.Stride * h];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(d);

        bool[] isBarRow = new bool[h];
        int sampleStep = 4;
        for (int row = 0; row < h; row++) {
            int red = 0, total = 0;
            int baseIdx = row * d.Stride;
            for (int col = 0; col < w; col += sampleStep) {
                int i = baseIdx + col * 4;
                byte b = buf[i], g2 = buf[i + 1], r = buf[i + 2];
                total++;
                // bright, strongly red-dominant
                if (r > 150 && g2 < 110 && b < 110 && (r - g2) > 70 && (r - b) > 70) red++;
            }
            isBarRow[row] = total > 0 && ((double)red / total) > 0.45;
        }

        // longest contiguous run
        int bestTop = -1, bestBot = -1, bestLen = 0;
        int curTop = -1;
        for (int row = 0; row < h; row++) {
            if (isBarRow[row]) {
                if (curTop < 0) curTop = row;
            } else if (curTop >= 0) {
                int len = row - curTop;
                if (len > bestLen) { bestLen = len; bestTop = curTop; bestBot = row - 1; }
                curTop = -1;
            }
        }
        if (curTop >= 0 && (h - curTop) > bestLen) { bestLen = h - curTop; bestTop = curTop; bestBot = h - 1; }

        // a real bar is a chunky band, not a stray scanline
        if (bestLen < 8) return new int[] { -1, -1 };
        return new int[] { bestTop, bestBot };
    }

    // White text on red -> black text on white, upscaled. Windows OCR likes clean contrast.
    public static Bitmap Binarize(Bitmap src, int scale) {
        int w = src.Width, h = src.Height;
        BitmapData d = src.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] buf = new byte[d.Stride * h];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        src.UnlockBits(d);

        Bitmap mask = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        BitmapData md = mask.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        byte[] mbuf = new byte[md.Stride * h];
        for (int row = 0; row < h; row++) {
            for (int col = 0; col < w; col++) {
                int i = row * d.Stride + col * 4;
                byte b = buf[i], g2 = buf[i + 1], r = buf[i + 2];
                // the glyphs are near-white: high in all channels
                bool text = r > 180 && g2 > 150 && b > 150;
                byte v = text ? (byte)0 : (byte)255;
                int mi = row * md.Stride + col * 4;
                mbuf[mi] = v; mbuf[mi + 1] = v; mbuf[mi + 2] = v; mbuf[mi + 3] = 255;
            }
        }
        Marshal.Copy(mbuf, 0, md.Scan0, mbuf.Length);
        mask.UnlockBits(md);

        Bitmap big = new Bitmap(w * scale, h * scale, PixelFormat.Format32bppArgb);
        using (Graphics g3 = Graphics.FromImage(big)) {
            g3.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g3.DrawImage(mask, 0, 0, w * scale, h * scale);
        }
        mask.Dispose();
        return big;
    }
}
'@
if (-not ("ThumperShot" -as [type])) {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Windows.Forms
}

# --- WinRT OCR plumbing ---
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($op, $type) {
    $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
    $t.Result
}
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime] | Out-Null

function Invoke-Ocr([string]$path) {
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) { throw "No OCR engine available" }
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync(0)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $res = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    $stream.Dispose()
    return $res.Text
}

# --- run ---
# Must precede any screen metric query, or we grab a DPI-virtualized downscale.
[void][ThumperShot]::SetProcessDPIAware()
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$shot = [ThumperShot]::Grab($vs.X, $vs.Y, $vs.Width, $vs.Height)

$bar = [ThumperShot]::FindBar($shot)
if ($bar[0] -lt 0) {
    $shot.Dispose()
    Write-Output "BAR=none"
    exit 0
}
Write-Output ("BAR=rows {0}-{1} (height {2})" -f $bar[0], $bar[1], ($bar[1] - $bar[0] + 1))

# Detection only locks onto the bar's solid core; the glyphs overshoot it well above and
# below. Crop a fixed band around the bar's center instead - wide enough for full letter
# height, narrow enough to exclude the neighbouring menu rows (~64px apart at 1280p).
$center = [int](($bar[0] + $bar[1]) / 2)
$half = [int]($shot.Height * 0.028)
$top = [math]::Max(0, $center - $half)
$bot = [math]::Min($shot.Height - 1, $center + $half)
$x0 = if ($XStart -gt 0) { $XStart } else { 0 }
$x1 = if ($XEnd -gt 0 -and $XEnd -le $shot.Width) { $XEnd } else { $shot.Width }
$rect = New-Object System.Drawing.Rectangle($x0, $top, ($x1 - $x0), ($bot - $top + 1))
$strip = $shot.Clone($rect, $shot.PixelFormat)
$shot.Dispose()

$clean = [ThumperShot]::Binarize($strip, $Upscale)
$strip.Dispose()

$tmpDir = Join-Path $env:TEMP "thumper_ocr"
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
$tmp = Join-Path $tmpDir "strip.png"
$clean.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$clean.Dispose()

$text = (Invoke-Ocr $tmp).Trim()
Write-Output "TEXT=$text"

if ($SaveDebug) {
    $dbgDir = Join-Path $PSScriptRoot "..\..\captures"
    if (-not (Test-Path $dbgDir)) { New-Item -ItemType Directory -Path $dbgDir -Force | Out-Null }
    $dbg = Join-Path (Resolve-Path $dbgDir).Path ("strip_{0}.png" -f (Get-Date -Format "HHmmss"))
    Copy-Item $tmp $dbg -Force
    Write-Output "DEBUG=$dbg"
} else {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
