<#
ReadLeaderboardRow.ps1 - read the selected row on Thumper's Leaderboards screen.

Diagnostic / prototype tool. This screen does NOT use the bright red fill bar that every
other menu uses - the selected row is marked with a thin GOLD outline (a rounded rectangle
border, not a filled row), so ReadSelection.ps1's FindBar cannot see it. This script finds
the gold border instead: two thin horizontal bands (top edge, bottom edge) rather than one
solid block.

Usage:
  .\ReadLeaderboardRow.ps1                # detect box, OCR rank+name and score, print both
  .\ReadLeaderboardRow.ps1 -SaveDebug      # also keep the cropped strips for inspection
#>
param(
    [switch]$SaveDebug,
    [int]$Upscale = 3
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class ThumperLb {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public static Bitmap Grab(int x, int y, int w, int h) {
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
        return bmp;
    }

    static byte[] Pixels(Bitmap bmp, out int stride) {
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height),
                                    ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] buf = new byte[d.Stride * bmp.Height];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(d);
        stride = d.Stride;
        return buf;
    }

    // The selection box border is gold: R and G both elevated and close to each other,
    // B near zero. Measured on a real capture: peak ~(129,109,0). This is what tells it
    // apart from the bright red fill bar used everywhere else (R >> G, B there).
    static bool IsGold(byte r, byte g, byte b) {
        return r > 70 && g > 55 && b < 50 && Math.Abs(r - g) < 45 && r >= g;
    }

    // The border is a thin outline, not a fill: the top and bottom edges are each only a
    // few px thick, and the rows between them are ordinary row content (background/text),
    // not gold. So look for the topmost gold band, then a second gold band, spaced by a
    // gap in the range a whole row occupies. Returns {contentTop, contentBot, boxLeft,
    // boxRight} using the INSIDE of the border (safe to OCR - excludes the border itself),
    // or {-1,-1,-1,-1} if not found.
    public static int[] FindGoldBox(Bitmap bmp) {
        int stride;
        byte[] buf = Pixels(bmp, out stride);
        int w = bmp.Width, h = bmp.Height;

        bool[] goldRow = new bool[h];
        for (int row = 0; row < h; row++) {
            int gold = 0, total = 0, baseIdx = row * stride;
            for (int col = 0; col < w; col += 4) {
                int i = baseIdx + col * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                total++;
                if (IsGold(r, g, b)) gold++;
            }
            goldRow[row] = total > 0 && ((double)gold / total) > 0.25;
        }

        System.Collections.Generic.List<int[]> runs = new System.Collections.Generic.List<int[]>();
        int cur = -1;
        for (int row = 0; row < h; row++) {
            if (goldRow[row]) { if (cur < 0) cur = row; }
            else if (cur >= 0) { runs.Add(new int[] { cur, row - 1 }); cur = -1; }
        }
        if (cur >= 0) runs.Add(new int[] { cur, h - 1 });

        // Need at least two thin runs (top edge, bottom edge) with a plausible row-height
        // gap between them. Reject anything that looks like the solid red bar instead
        // (a single run much thicker than a border line).
        for (int i = 0; i + 1 < runs.Count; i++) {
            int topEdgeBot = runs[i][1];
            int botEdgeTop = runs[i + 1][0];
            int topLen = runs[i][1] - runs[i][0] + 1;
            int gap = botEdgeTop - topEdgeBot - 1;
            // Border lines measured ~4px on a 1080p-ish capture; row interior gap is the
            // bulk of a row's height. Scale thresholds off image height, not fixed pixels.
            double rowH = h * 0.001; // ~1px per 1000 of image height as a coarse unit
            if (topLen < h && topLen <= System.Math.Max(2, (int)(rowH * 10)) &&
                gap > (int)(rowH * 15) && gap < (int)(rowH * 60)) {
                int contentTop = topEdgeBot + 1;
                int contentBot = botEdgeTop - 1;
                return new int[] { contentTop, contentBot };
            }
        }
        return new int[] { -1, -1 };
    }

    // Widest horizontal gap between "has content" columns in the row, to split rank+name
    // (left) from score+badge (right) - same idea as the narrator's Get-RowSplit.
    public static int FindSplit(Bitmap bmp, int top, int bot) {
        int stride;
        byte[] buf = Pixels(bmp, out stride);
        int w = bmp.Width;
        bool[] colHas = new bool[w];
        for (int col = 0; col < w; col++) {
            int count = 0;
            for (int row = top; row <= bot; row++) {
                int i = row * stride + col * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                // Near-white only. A looser threshold also catches Thumper's animated
                // background beams sweeping through the gap between name and score, which
                // breaks the gap up and lets the empty screen margin win instead.
                if (r > 180 && g > 150 && b > 150) count++;
            }
            colHas[col] = count >= 1;
        }
        int bestGapLen = 0, bestGapMid = w / 2;
        int runStart = -1;
        for (int col = 0; col < w; col++) {
            if (!colHas[col]) { if (runStart < 0) runStart = col; }
            else if (runStart >= 0) {
                // A run starting at the left screen edge is the margin outside the list,
                // not the gap inside a row.
                if (runStart > 0) {
                    int len = col - runStart;
                    if (len > bestGapLen) { bestGapLen = len; bestGapMid = (runStart + col) / 2; }
                }
                runStart = -1;
            }
        }
        return bestGapMid;
    }

    public static Bitmap Binarize(Bitmap src, int top, int bot, int scale, int xStart, int xEnd) {
        int stride;
        byte[] buf = Pixels(src, out stride);
        int x0 = (xStart > 0) ? xStart : 0;
        int x1 = (xEnd > 0 && xEnd <= src.Width) ? xEnd : src.Width;
        if (x1 <= x0) { x0 = 0; x1 = src.Width; }
        int w = x1 - x0;
        int h = bot - top + 1;

        Bitmap mask = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        BitmapData md = mask.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        byte[] mbuf = new byte[md.Stride * h];
        for (int row = 0; row < h; row++) {
            int sBase = (top + row) * stride, dBase = row * md.Stride;
            for (int col = 0; col < w; col++) {
                int i = sBase + (col + x0) * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                // Only white text counts as ink. The gold rank badge is deliberately left
                // out here - it renders as noisy dithered gold, not clean fill, and turns
                // into OCR-confusing speckle. It needs measuring, not reading (like the
                // volume slider pips), so it is a separate problem - see notes.
                bool ink = r > 170 && g > 150 && b > 150;
                byte v = ink ? (byte)0 : (byte)255;
                int mi = dBase + col * 4;
                mbuf[mi] = v; mbuf[mi + 1] = v; mbuf[mi + 2] = v; mbuf[mi + 3] = 255;
            }
        }
        Marshal.Copy(mbuf, 0, md.Scan0, mbuf.Length);
        mask.UnlockBits(md);

        Bitmap big = new Bitmap(w * scale, h * scale, PixelFormat.Format32bppArgb);
        using (Graphics g2 = Graphics.FromImage(big)) {
            g2.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g2.DrawImage(mask, 0, 0, w * scale, h * scale);
        }
        mask.Dispose();
        return big;
    }
}
'@
if (-not ("ThumperLb" -as [type])) {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Windows.Forms
}

# --- WinRT OCR plumbing (same pattern as ReadSelection.ps1) ---
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

function Ocr-Region([System.Drawing.Bitmap]$shot, [int]$top, [int]$bot, [int]$xStart, [int]$xEnd, [string]$tag) {
    $clean = [ThumperLb]::Binarize($shot, $top, $bot, $Upscale, $xStart, $xEnd)
    $tmpDir = Join-Path $env:TEMP "thumper_ocr"
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $tmp = Join-Path $tmpDir "lb_$tag.png"
    $clean.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
    $text = (Invoke-Ocr $tmp).Trim()
    if ($SaveDebug) {
        $dbgDir = Join-Path $PSScriptRoot "..\..\captures"
        if (-not (Test-Path $dbgDir)) { New-Item -ItemType Directory -Path $dbgDir -Force | Out-Null }
        $dbg = Join-Path (Resolve-Path $dbgDir).Path ("lb_{0}_{1}.png" -f $tag, (Get-Date -Format "HHmmss"))
        Copy-Item $tmp $dbg -Force
        Write-Output "DEBUG_$tag=$dbg"
    }
    $clean.Dispose()
    return $text
}

# --- run ---
[void][ThumperLb]::SetProcessDPIAware()
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$shot = [ThumperLb]::Grab($vs.X, $vs.Y, $vs.Width, $vs.Height)

$box = [ThumperLb]::FindGoldBox($shot)
if ($box[0] -lt 0) {
    $shot.Dispose()
    Write-Output "BOX=none"
    exit 0
}
Write-Output ("BOX=rows {0}-{1} (height {2})" -f $box[0], $box[1], ($box[1] - $box[0] + 1))

$split = [ThumperLb]::FindSplit($shot, $box[0], $box[1])
Write-Output "SPLIT=$split"

$left = Ocr-Region $shot $box[0] $box[1] 0 $split "left"
$right = Ocr-Region $shot $box[0] $box[1] $split 0 "right"
$shot.Dispose()

Write-Output "LEFT=$left"
Write-Output "RIGHT=$right"
