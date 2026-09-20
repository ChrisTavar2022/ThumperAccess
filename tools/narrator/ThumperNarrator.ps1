<#
ThumperNarrator.ps1 - speaks Thumper's selected menu item through NVDA.

Thumper draws its UI itself (SDL2), so there is no accessibility tree to query. This
reads the screen instead: find the full-width red highlight bar that marks the current
selection, OCR the text on it, and speak it when it changes.

DO NOT RUN THIS DIRECTLY. Start the narrator with Start-Narrator.cmd, which is the only
entry point. It selects 32-bit PowerShell (required: the NVDA controller client is x86,
and this host is ARM64) and bypasses the execution policy for that one launch.

Stop with Ctrl+C.
#>
param(
    [int]$PollMs = 120,
    [int]$SettleMs = 180,
    [int]$Upscale = 2,
    [switch]$Quiet,      # print what it would say, don't actually speak
    [switch]$Verbose
)

# Only one narrator at a time. A second instance does not fail visibly - it just talks
# over the first one, which is worse than not starting at all.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*ThumperNarrator*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class ThumperVision {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    // Detail-key presses should only count while the game is actually in front, so the
    // narrator does not start talking because F8 was pressed in some other program.
    public static bool ThumperFocused() {
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try {
            System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById((int)pid);
            return p.ProcessName.StartsWith("THUMPER", StringComparison.OrdinalIgnoreCase);
        } catch { return false; }
    }

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

    // Rows that are mostly bright, strongly red-dominant = the selection bar.
    public static int[] FindBar(Bitmap bmp) {
        int stride;
        byte[] buf = Pixels(bmp, out stride);
        int w = bmp.Width, h = bmp.Height;

        bool[] bar = new bool[h];
        for (int row = 0; row < h; row++) {
            int red = 0, total = 0, baseIdx = row * stride;
            for (int col = 0; col < w; col += 4) {
                int i = baseIdx + col * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                total++;
                if (r > 150 && g < 110 && b < 110 && (r - g) > 70 && (r - b) > 70) red++;
            }
            bar[row] = total > 0 && ((double)red / total) > 0.45;
        }

        int bestTop = -1, bestBot = -1, bestLen = 0, cur = -1;
        for (int row = 0; row < h; row++) {
            if (bar[row]) { if (cur < 0) cur = row; }
            else if (cur >= 0) {
                int len = row - cur;
                if (len > bestLen) { bestLen = len; bestTop = cur; bestBot = row - 1; }
                cur = -1;
            }
        }
        if (cur >= 0 && (h - cur) > bestLen) { bestLen = h - cur; bestTop = cur; bestBot = h - 1; }
        if (bestLen < 8) return new int[] { -1, -1 };
        return new int[] { bestTop, bestBot };
    }

    // The Leaderboards screen is the one place that does NOT use the red fill bar. Its
    // selected row is marked with a thin GOLD outline - a rounded rectangle border - so
    // FindBar sees nothing there. Measured border colour on a real capture: peak
    // ~(129,109,0), i.e. R and G both raised and close together with B at zero, which is
    // what separates it from the red bar (R >> G there).
    static bool IsGold(byte r, byte g, byte b) {
        return r > 70 && g > 55 && b < 50 && Math.Abs(r - g) < 45 && r >= g;
    }

    // An outline is two thin edges with ordinary row content between them, not one solid
    // block, so this looks for a pair of thin gold bands a row-height apart rather than
    // the longest run. Returns {top, bot} strictly INSIDE the border, or {-1,-1}.
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

        for (int i = 0; i + 1 < runs.Count; i++) {
            int topLen = runs[i][1] - runs[i][0] + 1;
            int contentTop = runs[i][1] + 1;
            int contentBot = runs[i + 1][0] - 1;
            int gap = contentBot - contentTop + 1;
            double unit = h * 0.001;
            if (topLen > Math.Max(2, (int)(unit * 10))) continue;
            if (gap <= (int)(unit * 15) || gap >= (int)(unit * 60)) continue;

            // A real row has text in it. Without this check a gold-ish flash during
            // gameplay could pass as a selection box and break the narrator's silence.
            int bright = 0;
            for (int row = contentTop; row <= contentBot; row += 2) {
                int baseIdx = row * stride;
                for (int col = 0; col < w; col += 4) {
                    int k = baseIdx + col * 4;
                    byte b = buf[k], g = buf[k + 1], r = buf[k + 2];
                    if (r > 180 && g > 150 && b > 150) bright++;
                }
            }
            if (bright < 20) continue;

            return new int[] { contentTop, contentBot };
        }
        return new int[] { -1, -1 };
    }

    // Widest run of empty columns in a row band, used to split leaderboard rows into
    // "rank + name" and "score". Get-RowSplit is not reused here: its arrow-trimming
    // branch would fire on a score whose digits happen to segment into four-plus blobs
    // and chop the first and last digit off the number.
    public static int SplitColumn(Bitmap bmp, int top, int bot) {
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
                // background beams, which sweep through the gap between name and score
                // and split it into short runs - at which point the empty screen margin
                // becomes the widest gap and the rank number lands on the score side.
                if (r > 180 && g > 150 && b > 150) count++;
            }
            colHas[col] = count >= 1;
        }
        int bestLen = 0, bestMid = w / 2, runStart = -1;
        for (int col = 0; col < w; col++) {
            if (!colHas[col]) { if (runStart < 0) runStart = col; }
            else if (runStart >= 0) {
                // Skip the run that starts at the left screen edge: that is the margin
                // outside the list, not the gap inside a row.
                if (runStart > 0) {
                    int len = col - runStart;
                    if (len > bestLen) { bestLen = len; bestMid = (runStart + col) / 2; }
                }
                runStart = -1;
            }
        }
        // A trailing run reaching the right edge is the other margin, so it is ignored too.
        return bestMid;
    }

    // Coarse shape signature of the text inside the given rows: near-white pixel counts
    // bucketed across 32 columns. An exact hash is useless here - Thumper animates its
    // background and the bar shimmers, so anti-aliased glyph edges flip above and below
    // any brightness threshold every frame. Bucketed counts compared with a tolerance
    // absorb that jitter while still changing sharply when the actual word changes.
    public static int[] TextProfile(Bitmap bmp, int top, int bot) {
        return TextProfile(bmp, top, bot, 0, bmp.Width);
    }

    // xStart/xEnd narrow the profile to part of the width. This matters for the screen
    // title: spread across the whole screen, a one-digit change ("LEVEL 2" -> "LEVEL 3",
    // two glyphs with near-identical ink) moves far too few pixels in any one bucket to
    // clear the change threshold, and the level change goes unannounced. Profiling just
    // the title's own span makes the digit a large share of a bucket instead.
    public static int[] TextProfile(Bitmap bmp, int top, int bot, int xStart, int xEnd) {
        int stride;
        byte[] buf = Pixels(bmp, out stride);
        int buckets = 32;
        int[] prof = new int[buckets];
        int x0 = xStart < 0 ? 0 : xStart;
        int x1 = (xEnd > 0 && xEnd <= bmp.Width) ? xEnd : bmp.Width;
        if (x1 <= x0) { x0 = 0; x1 = bmp.Width; }
        int span = x1 - x0;
        for (int row = top; row <= bot; row += 2) {
            int baseIdx = row * stride;
            for (int col = x0; col < x1; col += 2) {
                int i = baseIdx + col * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                if (r > 180 && g > 150 && b > 150) {
                    int bucket = ((col - x0) * buckets) / span;
                    if (bucket >= buckets) bucket = buckets - 1;
                    prof[bucket]++;
                }
            }
        }
        return prof;
    }

    // Per row, inside a central column window: how many bright (enabled label) and grey
    // (disabled label, e.g. a locked PLAY +) pixels there are. Used to find every menu
    // row so we can announce "item N of M", not just the highlighted text.
    // Returns a flat array [bright0, grey0, bright1, grey1, ...].
    public static int[] RowCounts(Bitmap bmp, double colLeft, double colRight) {
        int stride;
        byte[] buf = Pixels(bmp, out stride);
        int x0 = (int)(bmp.Width * colLeft), x1 = (int)(bmp.Width * colRight);
        int[] outp = new int[bmp.Height * 2];
        for (int row = 0; row < bmp.Height; row++) {
            int baseIdx = row * stride, bright = 0, grey = 0;
            for (int col = x0; col < x1; col++) {
                int i = baseIdx + col * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                if (r > 180 && g > 150 && b > 150) { bright++; }
                else {
                    int max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
                    if (max >= 95 && max <= 205 && (max - min) < 55) grey++;
                }
            }
            outp[row * 2] = bright;
            outp[row * 2 + 1] = grey;
        }
        return outp;
    }

    // Segment the right-hand side of the bar into white blobs by column projection.
    // Thumper draws volume-style settings as a row of pips: filled capsules up to the
    // current level, hollow rings beyond it, plus left/right arrows on the selected row.
    // OCR turns the rings into "0000000000", so measure the widget instead of reading it.
    // Returns [blobCount, filledCount, firstX, lastX, then (startX, width) per blob].
    public static int[] Blobs(Bitmap bmp, int barTop, int barBot, int xStart) {
        int stride;
        byte[] buf = Pixels(bmp, out stride);
        int w = bmp.Width;
        int x0 = xStart < 0 ? 0 : xStart;
        int midY = (barTop + barBot) / 2;

        bool[] colWhite = new bool[w];
        for (int col = x0; col < w; col++) {
            int count = 0;
            for (int row = barTop; row <= barBot; row++) {
                int i = row * stride + col * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                if (r > 180 && g > 150 && b > 150) count++;
            }
            colWhite[col] = count >= 2;
        }

        System.Collections.Generic.List<int> starts = new System.Collections.Generic.List<int>();
        System.Collections.Generic.List<int> ends = new System.Collections.Generic.List<int>();
        int cur = -1;
        for (int col = x0; col < w; col++) {
            if (colWhite[col]) { if (cur < 0) cur = col; }
            else if (cur >= 0) { if (col - cur >= 3) { starts.Add(cur); ends.Add(col - 1); } cur = -1; }
        }
        if (cur >= 0 && (w - cur) >= 3) { starts.Add(cur); ends.Add(w - 1); }

        // Per blob: start, width, and whether it is solid at mid-height. Reporting
        // solidity per blob (rather than one total) lets the caller drop the arrows
        // positionally and still know how many actual pips are filled.
        int n = starts.Count;
        int[] res = new int[1 + n * 3];
        res[0] = n;
        for (int k = 0; k < n; k++) {
            int cx = (starts[k] + ends[k]) / 2;
            int i = midY * stride + cx * 4;
            byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
            res[1 + k * 3] = starts[k];
            res[1 + k * 3 + 1] = ends[k] - starts[k] + 1;
            res[1 + k * 3 + 2] = (r > 180 && g > 150 && b > 150) ? 1 : 0;
        }
        return res;
    }

    // White glyphs on red -> black on white, upscaled: what the OCR engine wants.
    // xStart/xEnd clip horizontally so a row's label and its value can be read separately.
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
                byte v = (r > 180 && g > 150 && b > 150) ? (byte)0 : (byte)255;
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
if (-not ("ThumperVision" -as [type])) {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Windows.Forms
}
[void][ThumperVision]::SetProcessDPIAware()

# --- NVDA speech ---
# The NVDA controller client is NOT bundled - it is NV Access's DLL, not ours to
# redistribute - so look for wherever the user put it. See INSTALL.md.
$dllCandidates = @(
    (Join-Path $PSScriptRoot "..\..\lib\nvdaControllerClient32.dll"),
    (Join-Path $PSScriptRoot "..\tolk\libs\x86\nvdaControllerClient32.dll")
)
$nvdaDll = $null
foreach ($c in $dllCandidates) {
    if (Test-Path $c) { $nvdaDll = (Resolve-Path $c).Path; break }
}
if (-not $nvdaDll) {
    Write-Host ""
    Write-Host "Cannot find nvdaControllerClient32.dll - speech is not available."
    Write-Host "Download the NVDA Controller Client from nvaccess.org and copy the 32-bit"
    Write-Host "nvdaControllerClient32.dll into this folder:"
    Write-Host ("  " + (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "lib"))
    Write-Host "See INSTALL.md for the full steps."
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
$logDir = Join-Path $PSScriptRoot "..\..\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogPath = Join-Path ((Resolve-Path $logDir).Path) "speech.log"
Add-Content -Path $LogPath -Encoding UTF8 -Value ("=== narrator started {0} ===" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

function Write-SpeechLog([string]$text) {
    try {
        Add-Content -Path $LogPath -Encoding UTF8 -Value ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $text)
    } catch {
        # Never let logging take the narrator down mid-session.
    }
}

function Say([string]$text) {
    Write-SpeechLog $text
    if ($Quiet) { Write-Host "[would speak] $text"; return }
    [void][Nvda]::nvdaController_cancelSpeech()
    [void][Nvda]::nvdaController_speakText($text)
}

# --- OCR engine (created once) ---
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

$ocr = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $ocr) { Write-Error "No Windows OCR engine available"; exit 1 }

$tmpDir = Join-Path $env:TEMP "thumper_narrator"
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
$tmpFile = Join-Path $tmpDir "strip.png"

function Read-Strip([System.Drawing.Bitmap]$shot, [int]$top, [int]$bot, [int]$xStart = 0, [int]$xEnd = 0) {
    # Windows OCR gives up on small targets - a tightly cropped "ON" or "MSAA" comes back
    # empty at the scale that reads a full-width row fine. Upscale narrow crops harder.
    $span = (&{ if ($xEnd -gt 0) { $xEnd } else { $shot.Width } }) - $xStart
    $scale = if ($span -lt 700) { 5 } elseif ($span -lt 1200) { 3 } else { $Upscale }
    $clean = [ThumperVision]::Binarize($shot, $top, $bot, $scale, $xStart, $xEnd)
    $clean.Save($tmpFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $clean.Dispose()
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmpFile)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync(0)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $res = Await ($ocr.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    $stream.Dispose()
    return $res.Text.Trim()
}

# Find the screen title's actual bounds rather than assuming fixed proportions. Guessing
# fractions failed both ways: too tall caught the level-selector pip row and OCR read
# "LEVELL-" (pips become dashes, digit lost), too short returned nothing at all.
# The title is by far the tallest text block up there, so pick the tallest band and crop
# to the glyphs horizontally too - OCR returns empty for small text on a wide blank canvas.
function Get-TitleBox([System.Drawing.Bitmap]$shot) {
    $counts = [ThumperVision]::RowCounts($shot, 0.20, 0.80)
    $h = $shot.Height
    $limit = [int]($h * 0.22)

    $bands = New-Object System.Collections.ArrayList
    $cur = $null
    for ($y = 0; $y -lt $limit; $y++) {
        if ($counts[$y * 2] -ge 6) {
            if (-not $cur) { $cur = [pscustomobject]@{ Top = $y; Bot = $y } }
            $cur.Bot = $y
        } elseif ($cur) { [void]$bands.Add($cur); $cur = $null }
    }
    if ($cur) { [void]$bands.Add($cur) }
    if ($bands.Count -lt 1) { return $null }

    $best = $bands | Sort-Object { $_.Bot - $_.Top } -Descending | Select-Object -First 1
    if (($best.Bot - $best.Top) -lt ($h * 0.035)) { return $null }

    $pad = [int]($h * 0.006)
    $top = [math]::Max(0, $best.Top - $pad)
    $bot = [math]::Min($h - 1, $best.Bot + $pad)

    $r = [ThumperVision]::Blobs($shot, $top, $bot, 0)
    $n = $r[0]
    if ($n -lt 1) { return $null }
    $first = $r[1]
    $lastStart = $r[1 + ($n - 1) * 3]
    $lastWidth = $r[1 + ($n - 1) * 3 + 1]

    return [pscustomobject]@{
        Top    = $top
        Bot    = $bot
        Left   = [math]::Max(0, $first - 20)
        Right  = [math]::Min($shot.Width, $lastStart + $lastWidth + 20)
    }
}

# OCR a horizontal band given as fractions of screen height, cropped to the glyphs it
# actually contains. The crop matters: small text left sitting on a wide blank canvas
# comes back empty from Windows OCR, which is the same trap Get-TitleBox works around.
function Read-BandText([System.Drawing.Bitmap]$shot, [double]$topFrac, [double]$botFrac) {
    $t = [int]($shot.Height * $topFrac)
    $b = [int]($shot.Height * $botFrac)
    if ($b -le $t) { return "" }
    $r = [ThumperVision]::Blobs($shot, $t, $b, 0)
    $n = $r[0]
    if ($n -lt 1) { return "" }
    $first = $r[1]
    $lastStart = $r[1 + ($n - 1) * 3]
    $lastWidth = $r[1 + ($n - 1) * 3 + 1]
    $left = [math]::Max(0, $first - 20)
    $right = [math]::Min($shot.Width, $lastStart + $lastWidth + 20)
    return Read-Strip $shot $t $b $left $right
}

# A leaderboard row is "rank + name" on the left and a score on the right. The row's own
# rank number IS its position, and the list runs to hundreds of entries, so this
# deliberately has no "item N of M" - unlike every other screen.
function Read-LeaderboardRow([System.Drawing.Bitmap]$shot, [int]$top, [int]$bot) {
    $split = [ThumperVision]::SplitColumn($shot, $top, $bot)
    $left = Read-Strip $shot $top $bot 0 $split
    $right = Read-Strip $shot $top $bot $split 0

    $rank = ""
    $name = ""
    $scoreText = $right
    if ($left -match '^\s*(\d+)\s+(.+)$') {
        $rank = $Matches[1]
        $name = $Matches[2].Trim()
    } else {
        # The split can still misfire on a bad frame, and then the whole row lands on one
        # side. Parse it as a single string rather than letting the rank digits glue
        # themselves onto the score and announce "3,280,000" for "rank 3 ... 280,000".
        $whole = ("$left $right").Trim()
        if ($whole -match '^(\d+)\s+(.+?)\s+([\d][\d.,]*)$') {
            $rank = $Matches[1]
            $name = $Matches[2].Trim()
            $scoreText = $Matches[3]
        } else {
            return ""
        }
    }

    # The thousands separator reads back as "," on one frame and "." on the next. Spoken
    # raw, "653.050" turns into "point zero five zero", so rebuild the number from its
    # digits instead of trusting the separator.
    $score = ""
    $digits = ($scoreText -replace '[^\d]', '')
    if ($digits -and $digits.Length -le 18) {
        $score = ([int64]$digits).ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    # Every row here has both a name and a score, so a read missing either is a
    # half-rendered frame rather than a real row. Announcing it gives "rank 1, NAME" with
    # no score, corrected a second later - better to say nothing and read again.
    if (-not $name -or -not $score) { return "" }

    $parts = @()
    if ($rank) { $parts += "rank $rank" }
    $parts += $name
    $parts += $score
    return ($parts -join ", ")
}

# Settings rows are laid out as label on the left, value on the right, separated by a wide
# gap. Windows OCR silently drops the isolated value across that gap - "FULLSCREEN ON"
# came back as just "FULLSCREEN" - so find the gap and read the two sides separately.
# Rows with a single centred label (PLAY, APPLY) have no such gap and are read whole.
function Get-RowSplit([System.Drawing.Bitmap]$shot, [int]$barTop, [int]$barBot) {
    $r = [ThumperVision]::Blobs($shot, $barTop, $barBot, 0)
    $n = $r[0]
    if ($n -lt 2) { return $null }

    $starts = @(); $ends = @()
    for ($k = 0; $k -lt $n; $k++) {
        $s = $r[1 + $k * 3]
        $starts += $s
        $ends += ($s + $r[1 + $k * 3 + 1] - 1)
    }

    $bestGap = 0; $bestAt = -1
    for ($k = 1; $k -lt $n; $k++) {
        $gap = $starts[$k] - $ends[$k - 1]
        if ($gap -gt $bestGap) { $bestGap = $gap; $bestAt = $k }
    }
    # Inter-letter gaps are a few pixels; a label/value split is a large fraction of width.
    if ($bestAt -lt 1 -or $bestGap -lt ($shot.Width * 0.06)) { return $null }

    # An adjustable row flanks its value with < and > arrows. Those arrow glyphs wreck
    # OCR: cropped with them, "ON" reads as nothing at all; cropped between them it reads
    # perfectly. So expose an inner range that excludes them, plus the outer start, which
    # is what slider detection wants (it trims the arrows itself).
    $vLo = $bestAt
    $vHi = $n - 1
    $valueStart = $starts[$vLo] - 8
    $valueEnd = 0
    if (($vHi - $vLo + 1) -ge 4) {
        $valueStart = $ends[$vLo] + 10
        $valueEnd = $starts[$vHi] - 10
    }

    return [pscustomobject]@{
        # Crop the label tightly on both sides. Left-anchoring at 0 leaves a short label
        # like "MSAA" as a speck on a very wide mostly-blank canvas, and OCR returns
        # nothing for it.
        LabelStart  = [math]::Max(0, $starts[0] - 8)
        LabelEnd    = $ends[$bestAt - 1] + 8
        ValueStart  = $valueStart
        ValueEnd    = $valueEnd
        GroupStart  = $starts[$vLo] - 8
    }
}

# Recognise a pip-row slider on the selected line and turn it into a number.
# The selected row also draws left/right arrows, which show up as narrower blobs at each
# end, so they are trimmed before counting rather than being mistaken for pips.
function Get-SliderValue([System.Drawing.Bitmap]$shot, [int]$barTop, [int]$barBot, [int]$xStart) {
    $r = [ThumperVision]::Blobs($shot, $barTop, $barBot, $xStart)
    $n = $r[0]
    if ($n -lt 10) { return $null }

    $starts = @(); $widths = @(); $solid = @()
    for ($k = 0; $k -lt $n; $k++) {
        $starts += $r[1 + $k * 3]
        $widths += $r[1 + $k * 3 + 1]
        $solid += $r[1 + $k * 3 + 2]
    }

    # The selected row always draws both arrows, so drop the outermost blob at each end by
    # position. Trimming by width instead misfires during the pip-fill animation, when an
    # arrow can momentarily measure as wide as a pip and inflate the count.
    $lo = 1; $hi = $n - 2
    $count = $hi - $lo + 1
    if ($count -lt 8) { return $null }

    $mid = @(); for ($k = $lo; $k -le $hi; $k++) { $mid += $widths[$k] }
    $median = ($mid | Sort-Object)[[int]($mid.Count / 2)]
    if ($median -le 0) { return $null }

    # Pips are uniform; if the middle blobs vary a lot this is text, not a slider.
    for ($k = $lo; $k -le $hi; $k++) {
        if ([math]::Abs($widths[$k] - $median) -gt ($median * 0.35)) { return $null }
    }

    # Pips also sit on an even pitch. Letters do not - "VSYNC" passed the width test alone
    # and was announced as "FRAME RATE slider set to 3, range 1 to 5".
    $pitches = @(); for ($k = $lo + 1; $k -le $hi; $k++) { $pitches += ($starts[$k] - $starts[$k - 1]) }
    $avgPitch = ($pitches | Measure-Object -Average).Average
    if ($avgPitch -le 0) { return $null }
    foreach ($p in $pitches) {
        if ([math]::Abs($p - $avgPitch) -gt ($avgPitch * 0.20)) { return $null }
    }

    $filled = 0
    for ($k = $lo; $k -le $hi; $k++) { if ($solid[$k] -eq 1) { $filled++ } }

    return [pscustomobject]@{ Value = $filled; Total = $count; StartX = $starts[0] }
}

# Menu rows are ~40px tall at 1280p; anything much shorter is a separator line or a stray
# highlight in the background art, anything taller is the title logo.
function Get-MenuPosition([System.Drawing.Bitmap]$shot, [int]$barCenter) {
    $counts = [ThumperVision]::RowCounts($shot, 0.28, 0.72)
    $h = $shot.Height
    # Keep this well above the first menu row. At 0.22 the Video menu's FULLSCREEN row sat
    # above the cutoff, so it was never counted: every row reported "of 5" instead of
    # "of 6" and FULLSCREEN itself got no position at all. Screen titles are excluded by
    # the band-height filter below (they are far taller than a menu row), not by this.
    $minRow = [int]($h * 0.10)
    $minBandH = [int]($h * 0.020)
    $maxBandH = [int]($h * 0.060)

    $bands = New-Object System.Collections.ArrayList
    $cur = $null
    for ($y = $minRow; $y -lt $h; $y++) {
        $bright = $counts[$y * 2]; $grey = $counts[$y * 2 + 1]
        if (($bright -ge 6) -or ($grey -ge 25)) {
            if (-not $cur) { $cur = [pscustomobject]@{ Top = $y; Bot = $y; Bright = 0; Grey = 0 } }
            $cur.Bot = $y; $cur.Bright += $bright; $cur.Grey += $grey
        } elseif ($cur) {
            if (($cur.Bot - $cur.Top + 1) -ge $minBandH -and ($cur.Bot - $cur.Top + 1) -le $maxBandH) { [void]$bands.Add($cur) }
            $cur = $null
        }
    }
    if ($cur -and ($cur.Bot - $cur.Top + 1) -ge $minBandH -and ($cur.Bot - $cur.Top + 1) -le $maxBandH) { [void]$bands.Add($cur) }
    if ($bands.Count -lt 1) { return $null }

    $selIdx = -1
    for ($i = 0; $i -lt $bands.Count; $i++) {
        if ($barCenter -ge ($bands[$i].Top - 6) -and $barCenter -le ($bands[$i].Bot + 6)) { $selIdx = $i; break }
    }
    if ($selIdx -lt 0) { return $null }

    # A screen can legitimately hold a single setting (Audio has only VOLUME). Without
    # this, such screens fall through the spacing logic below and get no position at all.
    if ($bands.Count -eq 1) { return [pscustomobject]@{ Index = 1; Total = 1 } }

    # Keep only the evenly-spaced run the selection belongs to, so a bright patch of
    # background art elsewhere on screen cannot inflate the count.
    # Use the pitch next to the selection as the reference, not the median of every gap on
    # screen. On the level select the rank grid and score line add tightly packed bands
    # well above the menu, which dragged the median away from the menu's own pitch: the
    # run then never extended upwards and every row reported "item 1 of N".
    $cand = @()
    if ($selIdx -gt 0) { $cand += ($bands[$selIdx].Top - $bands[$selIdx - 1].Top) }
    if ($selIdx -lt ($bands.Count - 1)) { $cand += ($bands[$selIdx + 1].Top - $bands[$selIdx].Top) }
    if ($cand.Count -lt 1) { return [pscustomobject]@{ Index = 1; Total = 1 } }
    $refGap = ($cand | Measure-Object -Minimum).Minimum
    if ($refGap -le 0) { return $null }

    # Group rows by PITCH from the selected row, not by list adjacency. Walking adjacent
    # bands broke on the level select screen, where stray bright bands from the background
    # art sit between the menu rows: the walk stopped at the first interloper and every row
    # announced "item 1 of N". Matching offsets that are whole multiples of the pitch
    # steps over those, and requiring the multiples to be consecutive stops the rank grid
    # far above from being swept in.
    $slots = @{}
    foreach ($bd in $bands) {
        $delta = $bd.Top - $bands[$selIdx].Top
        $k = [int][math]::Round($delta / $refGap)
        if ([math]::Abs($k) -gt 12) { continue }
        if ([math]::Abs($delta - ($k * $refGap)) -gt ($refGap * 0.30)) { continue }
        if (-not $slots.ContainsKey($k)) { $slots[$k] = $bd }
    }

    $kLo = 0; while ($slots.ContainsKey($kLo - 1)) { $kLo-- }
    $kHi = 0; while ($slots.ContainsKey($kHi + 1)) { $kHi++ }

    $selectable = 0; $posOfSel = 0
    for ($k = $kLo; $k -le $kHi; $k++) {
        $bd = $slots[$k]
        # A locked entry is drawn desaturated grey, with essentially no bright pixels.
        $enabled = $bd.Bright -gt $bd.Grey
        if ($k -eq 0) { $enabled = $true }
        if ($enabled) { $selectable++; if ($k -eq 0) { $posOfSel = $selectable } }
    }
    if ($selectable -lt 1 -or $posOfSel -lt 1) { return $null }
    return [pscustomobject]@{ Index = $posOfSel; Total = $selectable }
}

# --- level progress, read from the save file rather than OCR'd off the screen ---
# The level select screen draws the score and a grid of tiny rank letters. Those same
# values sit in the save file as plain text, verified character-for-character against the
# screen, so read them from there: it is exact, and it also covers sections that are too
# small to OCR reliably.
$saveParser = Join-Path $PSScriptRoot "..\savedata\ParseSave.ps1"
$script:LevelData = $null
$script:SaveStamp = $null
$script:SavePath = $null

function Update-LevelData {
    try {
        if (-not $script:SavePath) {
            $base = "C:\Program Files (x86)\Steam\steamapps\common\Thumper\savedata"
            $d = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $d) { return }
            $script:SavePath = Join-Path $d.FullName "data_0.sav"
        }
        if (-not (Test-Path $script:SavePath)) { return }
        # Re-read only when the game has actually saved, so finishing a level refreshes ranks.
        $stamp = (Get-Item $script:SavePath).LastWriteTimeUtc
        if ($script:SaveStamp -eq $stamp -and $script:LevelData) { return }
        $script:SaveStamp = $stamp
        $json = & $saveParser -Json 2>$null
        if ($json) { $script:LevelData = $json | ConvertFrom-Json }
    } catch {
        Write-Host "save read failed: $($_.Exception.Message)"
    }
}

function Get-LevelInfo([int]$number) {
    Update-LevelData
    if (-not $script:LevelData) { return $null }
    return $script:LevelData | Where-Object { $_.name -eq ("level{0}" -f $number) } | Select-Object -First 1
}

function Format-LevelSummary([int]$number) {
    $lv = Get-LevelInfo $number
    if (-not $lv) { return $null }
    $sections = @($lv.sections)
    $played = @($sections | Where-Object { $_ -ne 'NONE' }).Count
    $s = @($sections | Where-Object { $_ -eq 'S' }).Count
    # Report the all-time best as well as the current run. Reporting only the current run
    # is misleading: after restarting level 1 the narrator said "not played yet" while the
    # player still held a 115,250 rank A best.
    $best = @($lv.best)
    $bestPlayed = @($best | Where-Object { $_ -ne 'NONE' }).Count
    $bestS = @($best | Where-Object { $_ -eq 'S' }).Count

    if ($bestPlayed -eq 0 -and $played -eq 0) {
        return ("Level {0}, never played, {1} sections" -f $number, $sections.Count)
    }

    # A level can have sections played but no overall rank yet (it has not been finished).
    # "rank NONE" reads badly, so say it plainly.
    $rankPart = if ($lv.rank -eq 'NONE') { "not yet ranked" } else { "rank {0}" -f $lv.rank }
    $bestPart = "Level {0}, best score {1:N0}, {2}, {3} S ranks" -f $number, $lv.score, $rankPart, $bestS
    $runPart = if ($played -eq 0) {
        "current run not started"
    } else {
        "current run {0} of {1} sections" -f $played, $sections.Count
    }
    return "$bestPart. $runPart"
}

function Format-LevelDetail([int]$number) {
    $lv = Get-LevelInfo $number
    if (-not $lv) { return $null }
    # Read the all-time best per section, not the current run. The current run is usually
    # mostly empty, and "which sections have I got an S on" is the question being asked.
    $sections = @($lv.best)
    if (@($sections | Where-Object { $_ -ne 'NONE' }).Count -eq 0) { $sections = @($lv.sections) }
    $parts = @()
    for ($i = 0; $i -lt $sections.Count; $i++) {
        $r = $sections[$i]
        $parts += if ($r -eq 'NONE') { "{0} not played" -f ($i + 1) } else { "{0} {1}" -f ($i + 1), $r }
    }
    return ("Level {0} best ranks: {1}" -f $number, ($parts -join ', '))
}

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
Write-Host "Thumper narrator running on $($vs.Width)x$($vs.Height). Ctrl+C to stop."
Write-Host "On the level select screen, press F8 for section-by-section ranks."
if (-not $Quiet) { Say "Thumper narrator ready" }

$lastSpoken = ""
$lastBarTop = -1
$lastProfile = $null
$changeAt = [DateTime]::MinValue
$pendingRead = $false
$pendingPhrase = ""
$pendingTries = 0
$lastTitleProfile = $null
$titleAt = [DateTime]::MinValue
$titlePending = $false
$currentLevel = 0
$lastBoardKey = ""
$titleTries = 0
$f8Was = $false

while ($true) {
    $shot = $null
    try {
        $shot = [ThumperVision]::Grab($vs.X, $vs.Y, $vs.Width, $vs.Height)

        # Which selection widget is on screen decides everything below. Only look for the
        # Leaderboards gold outline when there is no red bar - every other screen has one,
        # so this costs nothing on the common path.
        $bar = [ThumperVision]::FindBar($shot)
        $gold = if ($bar[0] -lt 0) { [ThumperVision]::FindGoldBox($shot) } else { @(-1, -1) }

        # --- level select: announce which level, plus its score and ranks ---
        # The selection bar here sits on RESUME/RESTART/PRACTICE, so the bar logic alone
        # would never mention which level is showing. Watch the big title instead.
        # Stop above the level-selector pip row that sits under the title: included, OCR
        # renders those pips as dashes ("LEVELL-") and loses the digit.
        $titleTop = [int]($shot.Height * 0.03)
        $titleBot = [int]($shot.Height * 0.14)
        # Profile only the middle of the screen, where the centred title actually sits.
        # Across the full width a single changed digit does not move any bucket enough.
        $titleProf = [ThumperVision]::TextProfile($shot, $titleTop, $titleBot,
                                                  [int]($shot.Width * 0.30), [int]($shot.Width * 0.70))
        $titleChanged = $false
        if (-not $lastTitleProfile) {
            $titleChanged = $true
        } else {
            $td = 0; $tmax = 0
            for ($i = 0; $i -lt $titleProf.Length; $i++) {
                $d = [math]::Abs($titleProf[$i] - $lastTitleProfile[$i])
                $td += $d
                if ($d -gt $tmax) { $tmax = $d }
            }
            $titleChanged = ($tmax -ge 25)
        }
        $lastTitleProfile = $titleProf

        # A fresh title change gets a fresh retry budget. Without the reset, failed reads
        # on one level eat the allowance for the next, and paging quickly leaves later
        # levels unannounced.
        if ($titleChanged) { $titleAt = Get-Date; $titlePending = $true; $titleTries = 0 }
        if ($titlePending -and ((Get-Date) - $titleAt).TotalMilliseconds -ge 350) {
            $titlePending = $false
            $titleText = ""
            $box = Get-TitleBox $shot
            if ($box) { $titleText = Read-Strip $shot $box.Top $box.Bot $box.Left $box.Right }
            if ($Verbose) { Write-Host "[title] '$titleText'" }
            if ($titleText -match 'LEVEL\s*(\d+)') {
                $lvNum = [int]$Matches[1]

                # Level select and Leaderboards share the same "LEVEL N" title, so the
                # title alone cannot tell them apart - and announcing the save-file level
                # summary on the leaderboard would be plain wrong. Level select always has
                # the red bar (RESUME/RESTART/PRACTICE); the leaderboard never does, and
                # names its mode underneath the level pips ("GLOBAL RANKING"). Read that
                # line to be sure, since the board is still "LOADING" when the title lands.
                $mode = ""
                if ($bar[0] -lt 0) { $mode = Read-BandText $shot 0.19 0.26 }

                if ($mode -match 'RANK') {
                    $titleTries = 0
                    $boardKey = "$lvNum|$mode"
                    if ($boardKey -ne $lastBoardKey) {
                        $lastBoardKey = $boardKey
                        $currentLevel = $lvNum
                        $phrase = "Level $lvNum, $mode"
                        Write-Host "-> $phrase"
                        Say $phrase
                        $lastSpoken = ""
                    }
                } elseif ($bar[0] -ge 0) {
                    # Level select - it is the screen with the red bar. Requiring the bar
                    # matters: without it, a leaderboard caught mid-load (no readable mode
                    # line yet) fell in here, set $currentLevel as a side effect, and then
                    # the real "Level N, GLOBAL RANKING" was suppressed as a duplicate.
                    $titleTries = 0
                    $lastBoardKey = ""
                    if ($lvNum -ne $currentLevel) {
                        $currentLevel = $lvNum
                        $summary = Format-LevelSummary $lvNum
                        if ($summary) {
                            Write-Host "-> $summary"
                            Say $summary
                            # The bar row (RESTART etc) is unchanged across levels;
                            # clearing this lets it be re-announced after the summary.
                            $lastSpoken = ""
                        }
                    }
                } elseif ($titleTries -lt 8) {
                    # A LEVEL title with no bar and no mode line yet: the leaderboard
                    # shows LOADING for a moment after paging to another level. Come back
                    # and look again instead of giving up, or that level change is never
                    # announced at all.
                    $titleTries++
                    $titleAt = Get-Date
                    $titlePending = $true
                } else {
                    $titleTries = 0
                }
            } elseif ($titleText) {
                $titleTries = 0
                $currentLevel = 0
                $lastBoardKey = ""
            } elseif ($gold[0] -ge 0 -and $titleTries -lt 8) {
                # An empty title read on the Leaderboards screen is a failed OCR, not a
                # state worth acting on: the title is white text over an animated
                # background and intermittently comes back blank. With no retry here the
                # level change is never announced at all - this is the "sometimes it does
                # not say the level" symptom.
                $titleTries++
                $titleAt = Get-Date
                $titlePending = $true
            } else {
                $titleTries = 0
            }
        }

        # --- F8: read the section-by-section ranks for the level on screen ---
        $f8Down = ([ThumperVision]::GetAsyncKeyState(0x77) -band 0x8000) -ne 0
        if ($f8Down -and -not $f8Was -and [ThumperVision]::ThumperFocused()) {
            if ($currentLevel -gt 0) {
                $detail = Format-LevelDetail $currentLevel
                if ($detail) { Write-Host "-> $detail"; Say $detail }
            } else {
                Say "No level selected"
            }
        }
        $f8Was = $f8Down

        if ($bar[0] -lt 0 -and $gold[0] -ge 0) {
            # --- Leaderboards: selection is a thin gold outline, not the red bar ---
            # Same settle-then-confirm gating as the bar path: the box slides between rows
            # and the whole list slides when the page scrolls, and a read taken mid-slide
            # returns a smeared or half-scrolled row.
            $prof = [ThumperVision]::TextProfile($shot, $gold[0], $gold[1])
            $changed = $false
            if ($gold[0] -ne $lastBarTop -or -not $lastProfile) {
                $changed = $true
            } else {
                $diff = 0; $total = 0; $maxBucket = 0
                for ($i = 0; $i -lt $prof.Length; $i++) {
                    $d = [math]::Abs($prof[$i] - $lastProfile[$i])
                    $diff += $d
                    if ($d -gt $maxBucket) { $maxBucket = $d }
                    $total += $prof[$i]
                }
                $changed = ($total -gt 0) -and
                           (($diff -gt [math]::Max(60, $total * 0.20)) -or ($maxBucket -ge 10))
            }
            $lastBarTop = $gold[0]
            $lastProfile = $prof

            if ($changed) { $changeAt = Get-Date; $pendingRead = $true; $pendingTries = 0 }

            if ($pendingRead -and ((Get-Date) - $changeAt).TotalMilliseconds -ge $SettleMs) {
                $pendingRead = $false
                $phrase = Read-LeaderboardRow $shot $gold[0] $gold[1]
                if ($Verbose) { Write-Host ("[gold {0}-{1}] '{2}'" -f $gold[0], $gold[1], $phrase) }
                if (-not $phrase -and $pendingTries -lt 4) {
                    # An incomplete read (no score yet) returns nothing. Without an
                    # explicit retry the row would stay silent until something else on
                    # screen changed, which on a still list is never.
                    $pendingTries++
                    $changeAt = Get-Date
                    $pendingRead = $true
                }
                if ($phrase) {
                    $key = ($phrase -replace '\s', '').ToUpperInvariant()
                    if ($key -ne $lastSpoken) {
                        $pendingTries++
                        if ($key -eq $pendingPhrase -or $pendingTries -ge 4) {
                            $lastSpoken = $key
                            $pendingPhrase = ""
                            $pendingTries = 0
                            Write-Host "-> $phrase"
                            Say $phrase
                            # Paging to another level always drops the selection back to
                            # rank 1, so this is the moment to make sure the level itself
                            # was announced. The title's pixel profile alone is not a
                            # reliable trigger: between two levels only one digit changes.
                            # Re-checking is cheap and $lastBoardKey stops any repeat.
                            if ($phrase -match '^rank 1,') {
                                $titleAt = Get-Date
                                $titlePending = $true
                                $titleTries = 0
                            }
                        } else {
                            if ($Verbose) { Write-Host "   (unconfirmed: $phrase)" }
                            $pendingPhrase = $key
                            $changeAt = Get-Date
                            $pendingRead = $true
                        }
                    }
                }
            }
        } elseif ($bar[0] -lt 0) {
            # No selection widget at all: title screen, gameplay, or a screen without a
            # highlighted row.
            $lastBarTop = -1
            $lastProfile = $null
            $pendingRead = $false
            $pendingPhrase = ""
            $lastSpoken = ""
        } else {
            $center = [int](($bar[0] + $bar[1]) / 2)
            $half = [int]($shot.Height * 0.028)
            $top = [math]::Max(0, $center - $half)
            $bot = [math]::Min($shot.Height - 1, $center + $half)
            $prof = [ThumperVision]::TextProfile($shot, $bar[0], $bar[1])

            # The bar physically moves to the selected row, so its position is the cleanest
            # change signal. The profile catches the rest: same row, different text, which
            # is what happens when a submenu opens over the same layout.
            $changed = $false
            if ($bar[0] -ne $lastBarTop -or -not $lastProfile) {
                $changed = $true
            } else {
                $diff = 0; $total = 0; $maxBucket = 0
                for ($i = 0; $i -lt $prof.Length; $i++) {
                    $d = [math]::Abs($prof[$i] - $lastProfile[$i])
                    $diff += $d
                    if ($d -gt $maxBucket) { $maxBucket = $d }
                    $total += $prof[$i]
                }
                # Two different kinds of change matter. A whole new label moves a large
                # share of the pixels. A small value edit moves very few: toggling
                # "ON" to "OFF" on a row whose long label dominates the pixel count shifts
                # the busiest bucket by only ~26, and one slider pip is similar. Measured
                # resting jitter on a still menu is 1-3, so 10 separates them safely.
                $changed = ($total -gt 0) -and
                           (($diff -gt [math]::Max(60, $total * 0.20)) -or ($maxBucket -ge 10))
            }

            if ($Verbose) { Write-Host ("poll bar={0}-{1} changed={2} total={3} maxBucket={4}" -f $bar[0], $bar[1], $changed, $total, $maxBucket) }
            $lastBarTop = $bar[0]
            $lastProfile = $prof

            # The bar slides between rows rather than jumping, so reading the instant it
            # starts moving catches a smeared mid-animation frame. Wait for it to hold
            # still, then read exactly once.
            if ($changed) { $changeAt = Get-Date; $pendingRead = $true; $pendingTries = 0 }

            if ($pendingRead -and ((Get-Date) - $changeAt).TotalMilliseconds -ge $SettleMs) {
                $pendingRead = $false

                # Settings rows split into label and value. Read them separately, and
                # measure the value if it is a pip slider rather than OCRing it.
                $split = Get-RowSplit $shot $bar[0] $bar[1]
                $value = ""
                if ($split) {
                    $text = Read-Strip $shot $top $bot $split.LabelStart $split.LabelEnd
                    $slider = Get-SliderValue $shot $bar[0] $bar[1] $split.GroupStart
                    if ($slider) {
                        $value = "slider set to {0}, range 1 to {1}" -f $slider.Value, $slider.Total
                    } else {
                        $value = Read-Strip $shot $top $bot $split.ValueStart $split.ValueEnd
                    }
                } else {
                    $text = Read-Strip $shot $top $bot 0 0
                }
                if ($Verbose) { Write-Host ("[bar {0}-{1}] '{2}' / '{3}'" -f $bar[0], $bar[1], $text, $value) }
                if (($text -or $value) -and $text.Length -le 48) {
                    $pos = Get-MenuPosition $shot $center
                    $phrase = $text
                    if ($value) { $phrase = if ($text) { "$text, $value" } else { $value } }
                    if ($pos) { $phrase += ", item {0} of {1}" -f $pos.Index, $pos.Total }
                    # Compare on a whitespace-stripped key. OCR alternates between
                    # "1920X1280" and "1920X 1280" on the same row, and comparing raw text
                    # meant the two reads never agreed, so that row was never announced.
                    $key = ($phrase -replace '\s', '').ToUpperInvariant()
                    if ($key -ne $lastSpoken) {
                        # Screen transitions slide the whole list, so a single read taken
                        # mid-slide sees a partial menu and yields a wrong count ("2 of 2").
                        # Only speak once two consecutive reads agree.
                        # ...but OCR is not perfectly repeatable, and a row whose reads
                        # never quite agree would otherwise stay silent forever. After a
                        # few tries, say the latest read rather than skipping the row.
                        $pendingTries++
                        if ($key -eq $pendingPhrase -or $pendingTries -ge 4) {
                            $lastSpoken = $key
                            $pendingPhrase = ""
                            $pendingTries = 0
                            Write-Host "-> $phrase"
                            Say $phrase
                        } else {
                            if ($Verbose) { Write-Host "   (unconfirmed: $phrase)" }
                            $pendingPhrase = $key
                            $changeAt = Get-Date
                            $pendingRead = $true
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host "poll error: $($_.Exception.Message)"
    } finally {
        if ($shot) { $shot.Dispose() }
    }
    Start-Sleep -Milliseconds $PollMs
}




