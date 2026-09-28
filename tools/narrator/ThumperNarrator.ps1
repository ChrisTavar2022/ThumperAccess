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

    // Hotkey presses (the update installer's F1-F12) should only count while the game is
    // actually in front, so the narrator does not react to a key press in some other app.
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
            // A row is counted even if under half its pixels are the strict red fingerprint
            // above. A dense widget - a slider with enough pips, or a long label - covers
            // enough of a row with white glyph/pip pixels to push the *middle* rows of an
            // otherwise perfectly normal selection bar under a stricter threshold: measured
            // on the Audio screen's VOLUME row, the middle third dropped to 0.41-0.44
            // against 0.45, so only an 8px sliver at the very top of the ~50px bar passed -
            // far too short to OCR anything, and the row went silent. Measured background
            // red-fraction elsewhere on that same screen was 0 (this fingerprint is narrow:
            // strongly red-dominant AND dark on green/blue), so there is wide margin to drop
            // this without picking up stray background art.
            bar[row] = total > 0 && ((double)red / total) > 0.30;
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
# Current NVDA packages ship the 32-bit client as x86\nvdaControllerClient.dll; older ones
# named it nvdaControllerClient32.dll. Accept either.
$libDir = Join-Path (Split-Path (Split-Path $PSScriptRoot)) "lib"
$dllCandidates = @(
    (Join-Path $libDir "nvdaControllerClient.dll"),
    (Join-Path $libDir "nvdaControllerClient32.dll"),
    (Join-Path $PSScriptRoot "..\tolk\libs\x86\nvdaControllerClient32.dll")
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
#
# The "Restart from checkpoint?" screen (reached from RESTART mid-run) reuses this exact
# same gold-outline widget for a completely different row format - "LEVEL 1-14" style
# checkpoint labels, not rank/name/score. It is a single short, centred phrase, not a real
# two-column row, so it is read as ONE whole-row crop first (like "RESTORE DEFAULTS" or
# "APPLY" elsewhere) - splitting it via SplitColumn (built for a genuine wide name/score
# gap) picks an arbitrary small internal gap instead and cuts it into two fragments too
# short to OCR reliably, the same class of failure isolated single letters hit elsewhere.
# It never starts with a digit the way a leaderboard row does, so the two formats can never
# be mistaken for each other.
function Read-GoldRow([System.Drawing.Bitmap]$shot, [int]$top, [int]$bot) {
    $wholeRaw = Read-Strip $shot $top $bot 0 0
    if ($Verbose) { Write-Host "[gold raw] '$wholeRaw'" }
    if ($wholeRaw -match '^LEVEL\s+(\d+)\s*-\s*(.+)$') {
        $lvl = $Matches[1]
        $point = $Matches[2].Trim().TrimEnd('.').ToUpperInvariant()
        # The special "current position" checkpoint is marked with an Omega (Ω) glyph in
        # game - a rare enough character that Windows OCR's read of it isn't trustworthy
        # (could come back as the real glyph, "O", "0", "Q", or empty). Anything that isn't
        # cleanly numeric is safer treated as "current checkpoint" than risking a misread
        # digit, since it is the only non-numeric entry this list ever has.
        if ($point -match '^\d+$') {
            return "Level $lvl, checkpoint $point"
        } else {
            return "Level $lvl, current checkpoint"
        }
    }

    # Not a checkpoint row - fall back to the real two-column leaderboard split (rank+name
    # on the left, score on the right, across a genuine wide gap).
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

# The Controls screen (Options -> Controls) lays its rows out very differently from every
# other settings screen: the label sits far to the left (~x 0.19 of width) and the value far
# to the right (~x 0.65-0.76), both largely outside the centred column band every other
# reader assumes, and the value itself can mix real text ("SPACE", a single letter) with a
# small icon badge (an arrow, or the Enter/Select symbol) separated by "/". Classifying which
# icon is which shape was tried and abandoned: measured directly on a live capture, an
# arrow's aspect ratio and pixel-fill density turned out statistically indistinguishable
# from an ordinary letter's (a real "S" measured almost identical to the up/down arrow
# shapes, and one row's icon - "LEFT" - turned out to actually be a DOWN arrow, not left,
# so assuming label-matches-icon was also unsafe). Confidently naming a shape that
# unreliable risks stating a wrong key binding, which is worse than omitting it.
# So this reads text only: every action on this screen also has a real keyboard letter
# alongside its icon, so a keyboard player loses nothing they actually need. Each right-side
# blob cluster is OCR'd on its own and kept only if the result looks like a real key name
# (letters only) - an icon glyph reliably OCRs to nothing or symbol garbage, silently
# discarded here rather than risk speaking it.
function Read-ControlsValue([System.Drawing.Bitmap]$shot, [int]$barTop, [int]$barBot) {
    $w = $shot.Width
    $r = [ThumperVision]::Blobs($shot, $barTop, $barBot, 0)
    $n = $r[0]
    if ($n -lt 1) { return "" }

    $starts = @(); $widths = @()
    for ($k = 0; $k -lt $n; $k++) { $starts += $r[1 + $k * 3]; $widths += $r[1 + $k * 3 + 1] }

    # Value-side blobs only - measured live, every label ends by x 0.38 of width and every
    # value starts no earlier than x 0.62, a wide and reliable gap between the two here.
    $valueMin = [int]($w * 0.55)
    $idx = @(); for ($k = 0; $k -lt $n; $k++) { if ($starts[$k] -ge $valueMin) { $idx += $k } }
    if ($idx.Count -lt 1) { return "" }

    # Group into clusters: a multi-letter word's own letters sit a few px apart; an icon and
    # its neighbouring text sit 70px+ apart - measured live, a clean, wide gap between them.
    $clusters = @()
    $cur = $null
    foreach ($k in $idx) {
        if (-not $cur) { $cur = [pscustomobject]@{ Start = $starts[$k]; End = $starts[$k] + $widths[$k] - 1 } }
        elseif (($starts[$k] - $cur.End) -le 20) { $cur.End = $starts[$k] + $widths[$k] - 1 }
        else { $clusters += $cur; $cur = [pscustomobject]@{ Start = $starts[$k]; End = $starts[$k] + $widths[$k] - 1 } }
    }
    if ($cur) { $clusters += $cur }

    $parts = @()
    foreach ($c in $clusters) {
        $left = [math]::Max(0, $c.Start - 10)
        $right = [math]::Min($w, $c.End + 10)
        # Crop tight to the glyph's own height, not the full ~54px bar - the same "small
        # text on a mostly blank canvas returns nothing" trap Get-TitleBox works around
        # elsewhere. A single letter measured about half the bar's height; left at full bar
        # height it read as empty every time live, and cropping to its own bounds fixed it.
        $topY = -1; $botY = -1
        for ($y = $barTop; $y -le $barBot; $y++) {
            $rowHas = $false
            for ($x = $c.Start; $x -le $c.End; $x += 2) {
                $px = $shot.GetPixel($x, $y)
                if ($px.R -gt 180 -and $px.G -gt 150 -and $px.B -gt 150) { $rowHas = $true; break }
            }
            if ($rowHas) { if ($topY -lt 0) { $topY = $y }; $botY = $y }
        }
        if ($topY -lt 0) { if ($Verbose) { Write-Host "[controls-value] cluster $($c.Start)-$($c.End) no rows found" }; continue }
        $topY = [math]::Max($barTop, $topY - 4)
        $botY = [math]::Min($barBot, $botY + 4)
        $rawText = Read-Strip $shot $topY $botY $left $right
        $text = $rawText -replace '[^A-Za-z]', ''
        if ($Verbose) { Write-Host "[controls-value] cluster $($c.Start)-$($c.End) y $topY-$botY crop $left-$right raw='$rawText' clean='$text'" }
        if ($text.Length -ge 1 -and $text.Length -le 12) { $parts += $text.ToUpperInvariant() }
    }
    return ($parts -join ' or ')
}

# Menu rows are ~40px tall at 1280p; anything much shorter is a separator line or a stray
# highlight in the background art, anything taller is the title logo.
# When a band comes out taller than a normal row, it is very likely real menu text fused
# with animated background bleed through the loose grey test - measured live on the level
# select screen, a stray blue/purple track line above RESUME merged with RESUME's own real
# ~35px text into a 66px band, one row over the limit, and the whole thing - including the
# real text - was silently dropped (RESUME vanished from the count entirely, which is why
# RESTART and PRACTICE both read "of 2" instead of "of 3"). Recover the real text instead of
# losing it: within the oversized band, find the tallest contiguous run of rows that qualify
# on BRIGHT ALONE - the signal every real row measured so far has had throughout, and the
# background bleed measured here never did - and use that if it is itself a normal row
# height. Falls back to nothing (the band is still dropped) if no such run exists, which is
# the previous, safe behaviour for a genuinely oversized non-text band.
function Get-BrightSubBand($counts, [int]$top, [int]$bot, [int]$minBandH, [int]$maxBandH) {
    $best = $null
    $cur = $null
    for ($y = $top; $y -le $bot; $y++) {
        if ($counts[$y * 2] -ge 6) {
            if (-not $cur) { $cur = [pscustomobject]@{ Top = $y; Bot = $y } }
            $cur.Bot = $y
        } elseif ($cur) {
            $height = $cur.Bot - $cur.Top + 1
            if ($height -ge $minBandH -and $height -le $maxBandH -and
                (-not $best -or $height -gt ($best.Bot - $best.Top + 1))) { $best = $cur }
            $cur = $null
        }
    }
    if ($cur) {
        $height = $cur.Bot - $cur.Top + 1
        if ($height -ge $minBandH -and $height -le $maxBandH -and
            (-not $best -or $height -gt ($best.Bot - $best.Top + 1))) { $best = $cur }
    }
    if (-not $best) { return $null }
    $obj = [pscustomobject]@{ Top = $best.Top; Bot = $best.Bot; Bright = 0; Grey = 0 }
    for ($y = $best.Top; $y -le $best.Bot; $y++) { $obj.Bright += $counts[$y * 2]; $obj.Grey += $counts[$y * 2 + 1] }
    return $obj
}

function Get-MenuPosition([System.Drawing.Bitmap]$shot, [int]$barCenter, [double]$colLeft = 0.28, [double]$colRight = 0.72) {
    $counts = [ThumperVision]::RowCounts($shot, $colLeft, $colRight)
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
            $height = $cur.Bot - $cur.Top + 1
            if ($height -ge $minBandH -and $height -le $maxBandH) { [void]$bands.Add($cur) }
            elseif ($height -gt $maxBandH) {
                $recovered = Get-BrightSubBand $counts $cur.Top $cur.Bot $minBandH $maxBandH
                if ($recovered) { [void]$bands.Add($recovered) }
            }
            $cur = $null
        }
    }
    if ($cur) {
        $height = $cur.Bot - $cur.Top + 1
        if ($height -ge $minBandH -and $height -le $maxBandH) { [void]$bands.Add($cur) }
        elseif ($height -gt $maxBandH) {
            $recovered = Get-BrightSubBand $counts $cur.Top $cur.Bot $minBandH $maxBandH
            if ($recovered) { [void]$bands.Add($recovered) }
        }
    }
    if ($bands.Count -lt 1) { return $null }

    # On a screen with few rows and no pip-row/score-line buffer under its title (Gameplay's
    # single HUD row is the clearest case), the title itself can land close enough to the
    # first real row to survive every other filter and get counted as an extra one - measured
    # live, Gameplay's title had a Bright sum of 14303 against HUD's real 3204, a >4x gap.
    # Titles consistently measure far brighter than a single row's label text across every
    # screen sampled (8800-14300 vs 3100-3450) - a large, reliable gap. A subtitle under a
    # title (Controls screen's grey "KEYBOARD" line) is the opposite problem: Bright is ~0,
    # below the enabled floor, so it could never be counted anyway - but left in, its gap to
    # the selected row still poisons refGap below (measured live: a 49px subtitle-to-row gap
    # got picked over the real ~59px row pitch, since the grouping always takes the smaller
    # of its two candidate gaps, and every real row after it then fell out of tolerance and
    # was silently dropped from the count). Drop the topmost band - as long as it is not the
    # selection itself - whenever it is either far brighter or implausibly dimmer than the
    # rest average out to, so neither failure mode gets a chance to corrupt the pitch below.
    for ($guard = 0; $guard -lt 2 -and $bands.Count -ge 2; $guard++) {
        $rest = $bands | Select-Object -Skip 1
        $restAvg = ($rest | Measure-Object -Property Bright -Average).Average
        $isSelected = $barCenter -ge ($bands[0].Top - 6) -and $barCenter -le ($bands[0].Bot + 6)
        if ($isSelected) { break }
        $tooBright = $restAvg -gt 0 -and $bands[0].Bright -gt (3 * $restAvg)
        $tooDim = $bands[0].Bright -le 200
        if ($tooBright -or $tooDim) { $bands.RemoveAt(0) } else { break }
    }
    if ($Verbose) {
        Write-Host ("[bands] " + (($bands | ForEach-Object { "$($_.Top)-$($_.Bot)(Br$($_.Bright)/Gr$($_.Grey))" }) -join " | "))
    }
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
        # A locked entry is drawn desaturated grey, with essentially no bright pixels - every
        # real row measured so far has had a Bright sum in the thousands, genuinely-locked/
        # background content close to 0. An absolute floor, not a Bright-vs-Grey comparison,
        # matters here: measured live on the level select screen, a real enabled row (its
        # own text fused with a stray blue/purple track line via the loose grey test) picked
        # up a Grey sum that exceeded its own real Bright sum, and the relative comparison
        # alone flipped it to "disabled" and dropped it from the count - which is why
        # RESTART and PRACTICE both read "item 2 of 2" instead of 2/3 and 3/3.
        $enabled = $bd.Bright -gt 200
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
$script:InstallDirWarned = $false

# Thumper's install folder was assumed to be under the default Steam library
# (C:\...\Steam\steamapps\common\Thumper), but every player's machine is different: Steam
# can have several libraries across drives, or Thumper might not be under Steam's default
# library at all, and a missing path fails silent (Get-ChildItem on a missing path just
# returns nothing, no error) - the level summary just quietly never speaks. Three ways to
# find it, in order: a player-set override, every Steam library the local client knows
# about, then the single-library default as a last resort.
function Find-ThumperInstallDir {
    $configPath = Join-Path $PSScriptRoot "..\..\config\game-dir.txt"
    if (Test-Path $configPath) {
        $override = Get-Content $configPath -ErrorAction SilentlyContinue |
            Where-Object { $_ -and ($_.Trim() -notlike '#*') } | Select-Object -First 1
        if ($override -and (Test-Path $override.Trim())) { return $override.Trim() }
    }

    $roots = @("C:\Program Files (x86)\Steam")
    $vdf = "C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        $found = [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
        if ($found) { $roots = $found }
    }
    foreach ($r in $roots) {
        $candidate = Join-Path $r "steamapps\common\Thumper"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Update-LevelData {
    try {
        if (-not $script:SavePath) {
            $installDir = Find-ThumperInstallDir
            if (-not $installDir) {
                # A silent failure here is invisible to a blind player - the level select
                # screen would just never announce its summary, with nothing on screen to
                # explain why. Say it once (not every poll) so it is actually discoverable.
                if (-not $script:InstallDirWarned) {
                    $script:InstallDirWarned = $true
                    $msg = "Could not find the Thumper install folder. Level summaries " +
                           "are unavailable until you set it in config game-dir.txt. See INSTALL.md."
                    Write-Host $msg
                    Say $msg
                }
                return
            }
            $base = Join-Path $installDir "savedata"
            $d = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $d) { return }
            $script:SavePath = $d.FullName
        }
        # Thumper alternates between two save slots, data_0.sav and data_1.sav, on every
        # save - always reading data_0 left this one save behind about half the time. The
        # newest slot is the current one.
        $file = Get-ChildItem $script:SavePath -Filter 'data_*.sav' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if (-not $file) { return }
        # Re-read only when the game has actually saved, so finishing a level refreshes ranks.
        $stamp = "{0}|{1}" -f $file.Name, $file.LastWriteTimeUtc.Ticks
        if ($script:SaveStamp -eq $stamp -and $script:LevelData) { return }
        $json = & $saveParser -Json -Path $file.FullName 2>$null
        if (-not $json) { return }   # caught mid-write: leave the stamp, retry next time
        $script:SaveStamp = $stamp
        $old = $script:LevelData
        # Two steps on purpose: Windows PowerShell's ConvertFrom-Json emits a JSON array as
        # ONE object, so @($json | ConvertFrom-Json) wraps the whole array as a single item
        # and every level's sections then get merged into one 220-long list.
        $parsed = $json | ConvertFrom-Json
        $script:LevelData = @($parsed)
        if ($old) { Announce-SectionResults $old $script:LevelData }
    } catch {
        Write-Host "save read failed: $($_.Exception.Message)"
    }
}

# --- section results, announced straight from the save file ---
# Thumper saves after every finished section (confirmed 2026-09-28: consecutive slot writes
# 18 seconds apart, one more section filled in each time), so a changed save file IS the
# results screen, as exact data and with no OCR. Compare the current run's sections before
# and after: a section that is now played and differs in rank OR cumulative score was just
# finished. Comparing the score as well catches replaying a section (restart from
# checkpoint) and getting the same rank again. A restart that clears sections back to NONE
# is not announced - nothing was just finished.
#
# Only the rank letter is spoken ("S"), nothing else - a product decision (user,
# 2026-09-28): this plays mid-gameplay in a rhythm game, where the next obstacle can arrive
# at any moment, so anything longer competes with the music and the player's attention.
# Points, totals, "level complete" and new bests are left to the level select summary,
# which is heard outside gameplay. If several sections changed in one save (rare), only the
# furthest one is spoken - that is the section just finished.
function Announce-SectionResults($old, $new) {
    $rank = $null
    foreach ($lv in $new) {
        $prev = $old | Where-Object { $_.name -eq $lv.name } | Select-Object -First 1
        if (-not $prev) { continue }
        $ranks = @($lv.sections); $scores = @($lv.scores)
        $pRanks = @($prev.sections); $pScores = @($prev.scores)
        if ($ranks.Count -ne $pRanks.Count -or $scores.Count -ne $ranks.Count) { continue }
        for ($i = 0; $i -lt $ranks.Count; $i++) {
            if ($ranks[$i] -eq 'NONE') { continue }
            if ($ranks[$i] -eq $pRanks[$i] -and $scores[$i] -eq $pScores[$i]) { continue }
            $rank = $ranks[$i]
        }
    }
    if ($rank) { Say $rank }
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

# For the "Restart from checkpoint?" screen: the rank and points for the one section the
# highlighted checkpoint starts (checkpoint N = the start of section N - the list's top
# entry is always the first section not yet played this run). Per row, not a summary of
# every section on arrival: reading all 15 at once was too much to take in (user feedback
# 2026-09-28), and the row you are on is the one you are deciding about.
# Deliberately the CURRENT RUN ($lv.sections/$lv.scores), not the all-time best - the
# screen's own rank badges show this run, and that is what matters when picking where to
# restart from.
function Format-CheckpointSection([int]$number, [int]$section) {
    $lv = Get-LevelInfo $number
    if (-not $lv) { return $null }
    $ranks = @($lv.sections); $scores = @($lv.scores)
    $i = $section - 1
    if ($i -lt 0 -or $i -ge $ranks.Count) { return $null }
    if ($ranks[$i] -eq 'NONE') { return "not played yet" }
    if ($scores.Count -ne $ranks.Count) { return "rank {0}" -f $ranks[$i] }
    $before = if ($i -gt 0 -and $scores[$i - 1] -gt 0) { $scores[$i - 1] } else { 0 }
    return ("rank {0}, {1:N0} points" -f $ranks[$i], ($scores[$i] - $before))
}

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
Write-Host "Thumper narrator running on $($vs.Width)x$($vs.Height). Ctrl+C to stop."
if (-not $Quiet) { Say "Thumper narrator ready" }

# --- update check, once per launch ---
# A single check at startup, not on a timer: the narrator is typically relaunched once per
# play session anyway (more so with auto-start), so that already gives frequent-enough
# checks without adding a background timer. A blocked or slow request just means a few
# seconds' delay before the main loop starts - Check-Update.ps1 never throws, so a failed
# check (no internet, GitHub down, no release published yet) is silently a no-op here too.
$script:UpdateAvailable = $false
$script:UpdateUrl = ""
$updateChecker = Join-Path $PSScriptRoot "..\updater\Check-Update.ps1"
try {
    $updateJson = & $updateChecker 2>$null
    if ($updateJson) {
        $update = $updateJson | ConvertFrom-Json
        if ($update.Available) {
            $script:UpdateAvailable = $true
            $script:UpdateUrl = $update.Url
            $msg = "A new version, $($update.Version), is available. Press any F key to install it."
            Write-Host $msg
            Say $msg
        }
    }
} catch {
    # Same principle as everywhere else this narrator talks to the outside world (the save
    # file, the game window): a missing or broken updater must never take the narrator down.
}

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
$lastWidgetKind = ""
$lastLevelSummary = 0
$lastBoardKey = ""
$titleTries = 0
$goldReadAt = [DateTime]::MinValue
$fKeyWas = $false
# The highest "item N of M" total seen since the screen last changed. Backstop against
# Get-MenuPosition undercounting on a noisy frame (see the level select item-count fixes
# above it) - a real screen's row count does not legitimately shrink while you sit still on
# it, so a lower total than one already confirmed is treated as a bad read, not a real
# change. Reset alongside $lastSpoken wherever that already means "the screen changed."
$script:knownTotal = 0
# Read the save once up front, so the first section finished this session has a baseline
# to be compared against (see Announce-SectionResults).
Update-LevelData
$saveCheckAt = Get-Date

while ($true) {
    $shot = $null
    try {
        # Section results: poll the save file about once a second. Cheap - it is only
        # re-parsed when the game has actually written a new save.
        if (((Get-Date) - $saveCheckAt).TotalMilliseconds -ge 1000) {
            $saveCheckAt = Get-Date
            Update-LevelData
        }
        $shot = [ThumperVision]::Grab($vs.X, $vs.Y, $vs.Width, $vs.Height)

        # Which selection widget is on screen decides everything below. Both are checked on
        # every poll now - the "Restart from checkpoint?" screen (reached from RESTART
        # mid-run) showed this assumption was wrong: it has a real gold-outlined, navigable
        # checkpoint list AND a separate static red "RESTART" confirm bar at the bottom, at
        # the same time - the only screen that does. That static bar is colour-identical to
        # a real selection bar, so FindBar happily matched it, and with gold only checked
        # when no bar was found, the actually-navigable gold list was never even looked at -
        # the screen read as a plain "RESTART" row and stayed silent about every checkpoint.
        # A gold box only ever appears on Leaderboards or this screen, never elsewhere, so
        # preferring it whenever found is safe everywhere else it's simply never present.
        $bar = [ThumperVision]::FindBar($shot)
        $gold = [ThumperVision]::FindGoldBox($shot)

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

        # Level select and Leaderboards can show the identical "LEVEL N" title pixels -
        # same text, same position - so going from one screen to the other at the same
        # level number moves nothing in the title profile, $titleChanged stays false, and
        # the whole branch below (bar vs. gold vs. mode) never even re-runs: the screen
        # changed but nothing gets re-announced. Force a re-check whenever which selection
        # widget is on screen flips, since that alone proves the screen changed.
        $widgetKind = if ($bar[0] -ge 0) { "bar" } elseif ($gold[0] -ge 0) { "gold" } else { "none" }
        if ($widgetKind -ne $lastWidgetKind) { $titleChanged = $true }
        $lastWidgetKind = $widgetKind

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
                        $phrase = "Level $lvNum, $mode"
                        Write-Host "-> $phrase"
                        Say $phrase
                        $lastSpoken = ""
                        $script:knownTotal = 0
                    }
                } elseif ($bar[0] -ge 0) {
                    # Level select - it is the screen with the red bar. Requiring the bar
                    # matters: without it, a leaderboard caught mid-load (no readable mode
                    # line yet) fell in here and the real "Level N, GLOBAL RANKING" was
                    # suppressed as a duplicate once it actually loaded.
                    $titleTries = 0
                    $lastBoardKey = ""
                    # Gated on its own tracker so checking Level 1's leaderboard and then
                    # returning to Level 1's select screen doesn't look like "no change" and
                    # silently suppress the summary - see notes/session-2026-09-27.
                    if ($lvNum -ne $lastLevelSummary) {
                        $lastLevelSummary = $lvNum
                        $summary = Format-LevelSummary $lvNum
                        if ($summary) {
                            Write-Host "-> $summary"
                            Say $summary
                            # The bar row (RESTART etc) is unchanged across levels;
                            # clearing this lets it be re-announced after the summary.
                            $lastSpoken = ""
                            $script:knownTotal = 0
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
                $lastLevelSummary = 0
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

        # --- update install: any F1-F12 key, but only while an update is actually pending ---
        # Only fires while $script:UpdateAvailable is true, which is rare (once a new
        # version has been announced) - exactly what was asked for, "press any of the top
        # keys" to install, not one specific key a blind player would need to have memorised.
        if ($script:UpdateAvailable) {
            $fKeyDown = $false
            for ($vk = 0x70; $vk -le 0x7B; $vk++) {
                if (([ThumperVision]::GetAsyncKeyState($vk) -band 0x8000) -ne 0) { $fKeyDown = $true; break }
            }
            if ($fKeyDown -and -not $fKeyWas -and [ThumperVision]::ThumperFocused()) {
                Say "Installing update. Please wait."
                $installer = Join-Path $PSScriptRoot "..\updater\Install-Update.ps1"
                try {
                    & $installer -Url $script:UpdateUrl
                    Say "Update installed. Restarting the narrator."
                    Start-Sleep -Milliseconds 1500
                    # A fresh process, not a re-run of this loop: the files this process
                    # already loaded (this very .ps1, among them) may have just been
                    # overwritten on disk, and only a new process picks up the new code.
                    # The new instance's own startup self-kill (top of this file) retires
                    # this one, the same way starting the narrator by hand always has.
                    Start-Process -FilePath (Join-Path $PSScriptRoot "Start-Narrator.cmd")
                    exit
                } catch {
                    Say "Update failed. Continuing with the current version."
                    Write-Host "update failed: $($_.Exception.Message)"
                    $script:UpdateAvailable = $false
                }
            }
            $fKeyWas = $fKeyDown
        }

        if ($gold[0] -ge 0) {
            # --- Leaderboards or Restart-from-checkpoint: a gold outline, not the red bar.
            # Takes priority over any red bar also found - see the comment above where both
            # are detected for why. ---
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

            # Heartbeat re-read. On the checkpoint list the gold box never moves - the list
            # scrolls under it - and "LEVEL 1-3" vs "LEVEL 1-4" differ by one digit, too
            # little for the profile test above. Caught 2026-09-28: a single Up press with
            # 2 seconds of quiet either side was never announced. Re-reading every 250ms
            # while the box sits still costs one OCR call; an unchanged row matches
            # $lastSpoken and is not repeated.
            if (-not $pendingRead -and ((Get-Date) - $goldReadAt).TotalMilliseconds -ge 250) {
                $pendingRead = $true
                $pendingTries = 0
                $changeAt = [DateTime]::MinValue
            }

            if ($pendingRead -and ((Get-Date) - $changeAt).TotalMilliseconds -ge $SettleMs) {
                $pendingRead = $false
                $goldReadAt = Get-Date
                $phrase = Read-GoldRow $shot $gold[0] $gold[1]
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
                        # A clean numbered checkpoint read is trusted without the usual
                        # second agreeing read: 76 of 76 reads were exact in a verbose
                        # run (2026-09-28), and the confirm step cost ~0.5s per row -
                        # enough that pressing again before it finished skipped the row.
                        # A mid-scroll crop does not match this strict pattern.
                        $cleanCheckpoint = $phrase -match '^Level \d+, checkpoint \d+$'
                        if ($key -eq $pendingPhrase -or $pendingTries -ge 4 -or $cleanCheckpoint) {
                            $lastSpoken = $key
                            $pendingPhrase = ""
                            $pendingTries = 0
                            # On the checkpoint screen, add that checkpoint's own section
                            # rank and points (see Format-CheckpointSection).
                            if ($phrase -match '^Level (\d+), checkpoint (\d+)$') {
                                $detail = Format-CheckpointSection ([int]$Matches[1]) ([int]$Matches[2])
                                if ($detail) { $phrase = "$phrase, $detail" }
                            }
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
            $script:knownTotal = 0
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

                # The Controls screen's rows (label far-left, value far-right with icon
                # glyphs mixed in) do not fit the label/value split above at all - see
                # Read-ControlsValue's own comment for the full reasoning. Detected off the
                # label text itself (already correctly read above) rather than a separate
                # title check, since every row on this screen has one of these exact labels
                # and nothing on any other screen does.
                $isControlsScreen = $text.Trim().ToUpperInvariant() -match
                    '^(ACTION|UP|LEFT|DOWN|RIGHT|QUICK RESTART|SELECT|RESTORE DEFAULTS)$'
                $isControlsRow = $isControlsScreen -and
                    $text.Trim().ToUpperInvariant() -ne 'RESTORE DEFAULTS'
                if ($isControlsRow) {
                    $value = Read-ControlsValue $shot $bar[0] $bar[1]
                }

                if ($Verbose) { Write-Host ("[bar {0}-{1}] '{2}' / '{3}'" -f $bar[0], $bar[1], $text, $value) }
                if (($text -or $value) -and $text.Length -le 48) {
                    if ($isControlsScreen) {
                        $pos = Get-MenuPosition $shot $center 0.15 0.85
                    } else {
                        $pos = Get-MenuPosition $shot $center
                    }
                    if ($pos) {
                        if ($pos.Total -gt $script:knownTotal) {
                            $script:knownTotal = $pos.Total
                        } elseif ($pos.Total -lt $script:knownTotal) {
                            # This read counted fewer rows than a total already confirmed on
                            # this exact screen - a real screen's row count does not shrink
                            # while you sit still on it, so this is background art bleeding
                            # into the row scan again (see the fixes above this function),
                            # not a real change. Don't speak a total known to be wrong - the
                            # label alone still gets said, and the next poll gets another
                            # chance at a clean read.
                            $pos = $null
                        }
                    }
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
                            # Level select and the main menu both use this same red bar, and
                            # the title-band change detector cannot be trusted to notice the
                            # difference: sitting on the main menu, the animated background
                            # in that band can jitter continuously and never let the 350ms
                            # settle window complete, so the title is never actually re-read
                            # and the level-summary memory below never gets cleared there. A
                            # confirmed row that is NOT one of level select's own
                            # (RESUME/RESTART/PRACTICE/START) proves we have left it, so
                            # clear the memory directly here instead - returning to the same
                            # level later then announces its summary again rather than
                            # staying silent because "that level was already announced".
                            if ($text -and ($text.Trim().ToUpperInvariant() -notmatch '^(RESUME|RESTART|PRACTICE|START)$')) {
                                $lastLevelSummary = 0
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
        }
    } catch {
        Write-Host "poll error: $($_.Exception.Message)"
    } finally {
        if ($shot) { $shot.Dispose() }
    }
    Start-Sleep -Milliseconds $PollMs
}




