# ScreenReading.ps1 - turning a screenshot into words: screen titles and dialog questions,
# leaderboard and checkpoint rows, a settings row's label and value, pip sliders, the
# Controls screen, and "item N of M". Dot-sourced by ThumperNarrator.ps1.

# The screen's own title ("OPTIONS", "AUDIO", ...), for prefixing the first row announced
# on a new screen. Returns "" for anything that does not look like a clean title (a
# half-slid-in frame, the THUMPER logo misread), and "-" for a "LEVEL N" title: read fine,
# but not spoken - level select and the pause menu already announce their level through
# their own paths - so the caller should not wait for a better read.
#
# A dialog ("EXIT GAME?" over NO/YES) has nothing in the usual title zone - its question
# sits just above the list, at ~0.30 of the height. So when that zone is empty, the
# nearest text line above the selected row is read instead, if it is clearly separated from
# it (a question stands apart from its answers; an ordinary row above the selection sits
# one row pitch away). Only when the title zone is EMPTY: the main menu has its logo up
# there, so it never falls through to reading PLAY as a "title".
function Read-ScreenTitle([System.Drawing.Bitmap]$shot, [int]$barTop) {
    $box = Get-TitleBox $shot
    if (-not $box) { $box = Get-QuestionBox $shot $barTop }
    if (-not $box) { return "" }
    $t = (Read-Strip $shot $box.Top $box.Bot $box.Left $box.Right).Trim()
    if ($Verbose) { Write-Host "[screen title] '$t'" }
    $t = ($t -replace '\s+', ' ').ToUpperInvariant()
    if ($t -match 'LEVEL\s*\d') { return "-" }
    if ($t -notmatch "^[A-Z][A-Z ?!']{2,40}$") { return "" }
    return $t
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

function Get-QuestionBox([System.Drawing.Bitmap]$shot, [int]$barTop) {
    $h = $shot.Height
    $counts = [ThumperVision]::RowCounts($shot, 0.20, 0.80)
    # The lowest text-height run above the bar. Shorter runs are skipped, not taken: a 2px
    # glint right above the dialog's bar would otherwise hide the question.
    $best = $null; $cur = $null
    for ($y = [int]($h * 0.22); $y -le $barTop; $y++) {
        if ($y -lt $barTop -and $counts[$y * 2] -ge 6) {
            if (-not $cur) { $cur = [pscustomobject]@{ Top = $y; Bot = $y } }
            $cur.Bot = $y
        } elseif ($cur) {
            $height = $cur.Bot - $cur.Top + 1
            if ($height -ge ($h * 0.025) -and $height -le ($h * 0.07)) { $best = $cur }
            $cur = $null
        }
    }
    if (-not $best) { return $null }
    # Measured on EXIT GAME?: ~135px from the question to the bar at 1080p; a plain row
    # above the selection is ~20px from the bar's top edge.
    if (($barTop - $best.Bot) -lt ($h * 0.06)) { return $null }

    $pad = [int]($h * 0.006)
    $top = [math]::Max(0, $best.Top - $pad)
    $bot = [math]::Min($h - 1, $best.Bot + $pad)
    $r = [ThumperVision]::Blobs($shot, $top, $bot, 0)
    $n = $r[0]
    if ($n -lt 1) { return $null }
    return [pscustomobject]@{
        Top   = $top
        Bot   = $bot
        Left  = [math]::Max(0, $r[1] - 20)
        Right = [math]::Min($shot.Width, $r[1 + ($n - 1) * 3] + $r[1 + ($n - 1) * 3 + 1] + 20)
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
    # "of 6" and FULLSCREEN itself got no position at all. But not above the screen titles
    # either: at 0.10 the Audio title (0.10-0.135 of height) was counted as a row sitting
    # exactly two row pitches above VOLUME, and Audio's one row read "item 2 of 2"
    # (2026-09-29). Every title seen sits above 0.14, every first row at 0.20 or below.
    $minRow = [int]($h * 0.15)
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
    # Measured between band CENTRES, not tops: a row whose band picks up bleed on one side
    # (the previous row's highlight still fading out, 2026-09-29: EXIT GAME's band started
    # 11px early) shifts its top by the whole bleed but its centre by only half, and the
    # shifted top dragged the pitch down to 43px and dropped two rows from the count.
    $mid = @(foreach ($bd in $bands) { ($bd.Top + $bd.Bot) / 2.0 })
    $cand = @()
    if ($selIdx -gt 0) { $cand += ($mid[$selIdx] - $mid[$selIdx - 1]) }
    if ($selIdx -lt ($bands.Count - 1)) { $cand += ($mid[$selIdx + 1] - $mid[$selIdx]) }
    if ($cand.Count -lt 1) { return [pscustomobject]@{ Index = 1; Total = 1 } }
    # Of the gaps to the neighbours above and below, take the one closest to a normal row
    # pitch rather than simply the smaller one. Every menu measured 2026-09-29 (main,
    # Options, Video, Controls, pause, level select, dialogs) spaces its rows 54-59px apart
    # at 1080p, ~0.052 of the height. On level select a faint patch of background art sits
    # 42px above RESUME; taking the minimum made that the pitch, PRACTICE fell off the
    # grid, and RESUME read "item 1 of 2" (or no count at all). A candidate far from the
    # normal pitch still falls back to the old minimum.
    $expected = $h * 0.052
    $near = @($cand | Where-Object { [math]::Abs($_ - $expected) -le ($expected * 0.35) })
    if ($near.Count -gt 0) {
        $refGap = ($near | Sort-Object { [math]::Abs($_ - $expected) } | Select-Object -First 1)
    } else {
        $refGap = ($cand | Measure-Object -Minimum).Minimum
    }
    if ($refGap -le 0) { return $null }

    # Group rows by PITCH from the selected row, not by list adjacency. Walking adjacent
    # bands broke on the level select screen, where stray bright bands from the background
    # art sit between the menu rows: the walk stopped at the first interloper and every row
    # announced "item 1 of N". Matching offsets that are whole multiples of the pitch
    # steps over those, and requiring the multiples to be consecutive stops the rank grid
    # far above from being swept in.
    $slots = @{}
    for ($bi = 0; $bi -lt $bands.Count; $bi++) {
        $bd = $bands[$bi]
        $delta = $mid[$bi] - $mid[$selIdx]
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
