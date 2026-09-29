// ThumperVision.cs - the narrator's pixel work: screen capture and every scan over a
// screenshot's raw pixels (selection bar, gold outline, text profiles, row counts, blobs,
// OCR binarization). C#, because the same loops in PowerShell are far too slow to run
// several times a second. Compiled at startup by ThumperNarrator.ps1 (Add-Type).

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

        // The main menu's animated background periodically floods the top of the screen
        // with bright red rays - runs of 130-260 rows at 1080p (2026-09-29), far taller than
        // the real ~50-row bar. Taken as the longest run, they replaced the real bar for
        // seconds at a time and every key press in that window went unannounced. Anything
        // taller than 8% of the screen cannot be a menu row, so it is skipped.
        int maxLen = (int)(h * 0.08);
        int bestTop = -1, bestBot = -1, bestLen = 0, cur = -1;
        for (int row = 0; row <= h; row++) {
            if (row < h && bar[row]) { if (cur < 0) cur = row; }
            else if (cur >= 0) {
                int len = row - cur;
                if (len > bestLen && len <= maxLen) { bestLen = len; bestTop = cur; bestBot = row - 1; }
                cur = -1;
            }
        }
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
