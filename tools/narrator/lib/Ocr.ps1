# Ocr.ps1 - Windows' built-in text recognition (Windows.Media.Ocr) over screenshot crops.
# Dot-sourced by ThumperNarrator.ps1, which defines $Upscale and $Verbose.

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
    return Read-Bitmap $clean
}

# OCR an already-prepared image, and dispose of it.
function Read-Bitmap([System.Drawing.Bitmap]$clean) {
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

# Windows OCR returns nothing for a lone short word: the Controls screen's "UP" label, a
# perfectly clean binarized crop, read as empty on 15 of 16 scale/padding combinations
# (2026-09-29) and was never once announced. Three copies side by side, half a glyph
# height apart, read as "UP UP UP" at every scale tried. Accepted only when all three
# copies agree AND the result is uppercase letters, as every Thumper label is: tiled, the
# Video screen's "4X" value came back "ax ax ax" - consistent, but wrong. For labels only -
# on the Controls screen's value side an arrow icon tiled the same way read as "t t t", a
# wrong key a player would act on, which is why single-letter key bindings stay unspoken.
function Read-StripTiled([System.Drawing.Bitmap]$shot, [int]$top, [int]$bot, [int]$xStart, [int]$xEnd) {
    $one = [ThumperVision]::Binarize($shot, $top, $bot, 5, $xStart, $xEnd)
    $gap = [int]($one.Height * 0.5); $pad = 20
    $tiled = New-Object System.Drawing.Bitmap ((3 * $one.Width) + (2 * $gap) + (2 * $pad)), ($one.Height + (2 * $pad))
    $g = [System.Drawing.Graphics]::FromImage($tiled)
    $g.Clear([System.Drawing.Color]::White)
    for ($i = 0; $i -lt 3; $i++) { $g.DrawImage($one, $pad + $i * ($one.Width + $gap), $pad, $one.Width, $one.Height) }
    $g.Dispose(); $one.Dispose()
    $words = @((Read-Bitmap $tiled) -split '\s+' | Where-Object { $_ })
    if ($words.Count -ne 3 -or $words[0] -ne $words[1] -or $words[1] -ne $words[2]) { return "" }
    if ($words[0] -cnotmatch '^[A-Z]{2,}$') { return "" }
    return $words[0]
}
