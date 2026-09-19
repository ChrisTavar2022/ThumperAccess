<#
ReadSlider.ps1 - diagnostic: measure a Thumper slider widget instead of OCRing it.

Thumper draws volume-style settings as a row of pips - filled capsules for the current
level, hollow rings for the rest, with left/right arrows on the selected row. OCR turns
those rings into "0000000000", which is the gibberish heard after "VOLUME". Counting the
pips geometrically gives a real value instead.
#>
param([double]$XFrom = 0.5)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class SliderScan {
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

    public static int[] FindBar(Bitmap bmp) {
        int stride; byte[] buf = Pixels(bmp, out stride);
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
        int bt = -1, bb = -1, bl = 0, cur = -1;
        for (int row = 0; row < h; row++) {
            if (bar[row]) { if (cur < 0) cur = row; }
            else if (cur >= 0) { int len = row - cur; if (len > bl) { bl = len; bt = cur; bb = row - 1; } cur = -1; }
        }
        if (cur >= 0 && (h - cur) > bl) { bl = h - cur; bt = cur; bb = h - 1; }
        if (bl < 8) return new int[] { -1, -1 };
        return new int[] { bt, bb };
    }

    // Segment the right-hand side of the bar into white blobs by column projection, then
    // classify each: solid at mid-height = filled pip, hollow centre = empty pip.
    // Returns [blobCount, filledCount, firstBlobX, lastBlobX, widths...] for inspection.
    public static int[] Blobs(Bitmap bmp, int barTop, int barBot, double xFrom) {
        int stride; byte[] buf = Pixels(bmp, out stride);
        int w = bmp.Width;
        int x0 = (int)(w * xFrom);
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

        int n = starts.Count;
        int[] res = new int[4 + n * 2];
        res[0] = n;
        int filled = 0;
        for (int k = 0; k < n; k++) {
            int cx = (starts[k] + ends[k]) / 2;
            int i = midY * stride + cx * 4;
            byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
            bool solid = (r > 180 && g > 150 && b > 150);
            if (solid) filled++;
            res[4 + k * 2] = starts[k];
            res[4 + k * 2 + 1] = ends[k] - starts[k] + 1;
        }
        res[1] = filled;
        res[2] = n > 0 ? starts[0] : -1;
        res[3] = n > 0 ? ends[n - 1] : -1;
        return res;
    }
}
'@
if (-not ("SliderScan" -as [type])) {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Windows.Forms
}
[void][SliderScan]::SetProcessDPIAware()

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$shot = [SliderScan]::Grab($vs.X, $vs.Y, $vs.Width, $vs.Height)
$bar = [SliderScan]::FindBar($shot)
if ($bar[0] -lt 0) { Write-Output "BAR=none"; $shot.Dispose(); exit 0 }
Write-Output ("BAR=rows {0}-{1}" -f $bar[0], $bar[1])

$r = [SliderScan]::Blobs($shot, $bar[0], $bar[1], $XFrom)
$shot.Dispose()
Write-Output ("BLOBS={0} FILLED={1} xrange={2}..{3}" -f $r[0], $r[1], $r[2], $r[3])
$n = $r[0]
$parts = @()
for ($k = 0; $k -lt $n; $k++) { $parts += ("x{0}(w{1})" -f $r[4 + $k * 2], $r[4 + $k * 2 + 1]) }
Write-Output ("SHAPES: " + ($parts -join " "))
