<#
ListItems.ps1 - diagnostic: find every menu row on screen, not just the selected one.

Needed for "PLAY, item 1 of 4" announcements. Thumper centres its menu list, so we scan
a central column window for horizontal bands of text-like pixels, then report each band
with the pixel counts used to classify it as enabled (near-white) or disabled (grey,
like a locked PLAY +).
#>
param(
    [double]$ColLeft = 0.28,
    [double]$ColRight = 0.72,
    [double]$TopSkip = 0.22
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class ItemScan {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public static Bitmap Grab(int x, int y, int w, int h) {
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
        return bmp;
    }

    // Per row: how many bright (enabled text) and grey (disabled text) pixels sit inside
    // the central column window. Returns a flat array [brightRow0, greyRow0, bright1, ...].
    public static int[] RowCounts(Bitmap bmp, double colLeft, double colRight) {
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height),
                                    ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] buf = new byte[d.Stride * bmp.Height];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(d);

        int x0 = (int)(bmp.Width * colLeft), x1 = (int)(bmp.Width * colRight);
        int[] outp = new int[bmp.Height * 2];
        for (int row = 0; row < bmp.Height; row++) {
            int baseIdx = row * d.Stride, bright = 0, grey = 0;
            for (int col = x0; col < x1; col++) {
                int i = baseIdx + col * 4;
                byte b = buf[i], g = buf[i + 1], r = buf[i + 2];
                if (r > 180 && g > 150 && b > 150) { bright++; }
                else {
                    int max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
                    // desaturated mid-tone = greyed-out label
                    if (max >= 95 && max <= 205 && (max - min) < 55) grey++;
                }
            }
            outp[row * 2] = bright;
            outp[row * 2 + 1] = grey;
        }
        return outp;
    }
}
'@
if (-not ("ItemScan" -as [type])) {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Windows.Forms
}
[void][ItemScan]::SetProcessDPIAware()

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$shot = [ItemScan]::Grab($vs.X, $vs.Y, $vs.Width, $vs.Height)
$counts = [ItemScan]::RowCounts($shot, $ColLeft, $ColRight)
$h = $shot.Height
$shot.Dispose()

$minRow = [int]($h * $TopSkip)
$bands = @()
$cur = $null
for ($y = $minRow; $y -lt $h; $y++) {
    $bright = $counts[$y * 2]
    $grey = $counts[$y * 2 + 1]
    $isText = ($bright -ge 6) -or ($grey -ge 25)
    if ($isText) {
        if (-not $cur) { $cur = [pscustomobject]@{ Top = $y; Bot = $y; Bright = 0; Grey = 0 } }
        $cur.Bot = $y
        $cur.Bright += $bright
        $cur.Grey += $grey
    } elseif ($cur) {
        $bands += $cur
        $cur = $null
    }
}
if ($cur) { $bands += $cur }

Write-Output ("screen {0}x{1}, scanning rows {2}..{1}" -f $vs.Width, $h, $minRow)
foreach ($b in $bands) {
    $height = $b.Bot - $b.Top + 1
    Write-Output ("band y={0,4}-{1,4} h={2,3} bright={3,6} grey={4,6}" -f $b.Top, $b.Bot, $height, $b.Bright, $b.Grey)
}
