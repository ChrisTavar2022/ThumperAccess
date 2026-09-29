# Announcer.ps1 - decides WHAT to say and WHEN, one poll at a time. The other modules turn
# pixels into words; this one tracks what changed since the last poll, waits for the screen
# to settle, confirms a read before trusting it, and avoids repeating itself.
# Dot-sourced by ThumperNarrator.ps1, which defines $SettleMs and $Verbose, and calls one
# step per poll (see its main loop). All state lives in the one $S object below.

$S = [pscustomobject]@{
    # --- the selected row (red bar or gold outline) ---
    LastSpoken       = ""    # whitespace-stripped key of the last row spoken
    LastBarTop       = -1
    LastProfile      = $null
    ChangeAt         = [DateTime]::MinValue
    PendingRead      = $false
    PendingPhrase    = ""    # an unconfirmed read, waiting for a second one to agree
    PendingTries     = 0
    GoldReadAt       = [DateTime]::MinValue
    # The highest "item N of M" total seen since the screen last changed. Backstop against
    # Get-MenuPosition undercounting on a noisy frame - a real screen's row count does not
    # shrink while you sit still on it, so a lower total than one already confirmed is
    # treated as a bad read, not a real change.
    KnownTotal       = 0
    # "LABEL, VALUE" pairs already confirmed by two agreeing reads this session - a later
    # first read that matches one exactly is trusted without waiting for a second.
    ConfirmedValues  = @{}
    LabelsWithValue  = @{}

    # --- follow-up re-reads of a row spoken incomplete (see Complete-BarAnnouncement) ---
    FollowUps        = 0
    FollowUpAt       = [DateTime]::MinValue
    IsFollowUp       = $false
    AnnouncedText    = ""
    AnnouncedValue   = $false
    AnnouncedPos     = $false
    AnnouncedTotal   = 0

    # --- screen titles prefixed to the first row of a new screen ---
    # TitleDirty: the screen may have changed (title band moved, or the selection vanished).
    # ScreenFresh: a read's row count was not yet confirmed - a new screen sliding in.
    TitleDirty       = $true
    ScreenFresh      = $true
    TitleWaits       = 0
    LastScreenTitle  = ""

    # --- the big "LEVEL N" title: level select summaries and leaderboard levels ---
    LastTitleProfile = $null
    TitleAt          = [DateTime]::MinValue
    TitlePending     = $false
    TitleTries       = 0
    LastWidgetKind   = ""
    LastLevelSummary = 0
    LastBoardKey     = ""
    QueueRowUntil    = [DateTime]::MinValue

    # --- update install hotkey ---
    UpdateAvailable  = $false
    UpdateUrl        = ""
    FKeyWas          = $false
}

# Shared by the red-bar and gold-outline paths: has the selection moved or its text
# changed since the last poll? Also records this poll as the new "last".
function Test-SelectionChanged([int]$top, $prof, [int]$tolerance) {
    $changed = $false
    $total = 0; $maxBucket = 0
    if ([math]::Abs($top - $S.LastBarTop) -gt $tolerance -or -not $S.LastProfile) {
        $changed = $true
    } else {
        $diff = 0
        for ($i = 0; $i -lt $prof.Length; $i++) {
            $d = [math]::Abs($prof[$i] - $S.LastProfile[$i])
            $diff += $d
            if ($d -gt $maxBucket) { $maxBucket = $d }
            $total += $prof[$i]
        }
        # Two different kinds of change matter. A whole new label moves a large share of
        # the pixels. A small value edit moves very few: toggling "ON" to "OFF" on a row
        # whose long label dominates the pixel count shifts the busiest bucket by only ~26,
        # and one slider pip is similar. Measured resting jitter on a still menu is 1-3, so
        # 10 separates them safely.
        $changed = ($total -gt 0) -and
                   (($diff -gt [math]::Max(60, $total * 0.20)) -or ($maxBucket -ge 10))
    }
    if ($Verbose) { Write-Host ("{0} poll top={1} changed={2} total={3} maxBucket={4}" -f (Get-Date -Format "ss.fff"), $top, $changed, $total, $maxBucket) }
    $S.LastBarTop = $top
    $S.LastProfile = $prof
    return $changed
}

# No selection widget at all: title screen, gameplay, or a screen without a highlighted
# row. Forget the selection so the next screen's first row is announced fresh.
function Reset-Selection {
    $S.LastBarTop = -1
    $S.LastProfile = $null
    $S.PendingRead = $false
    $S.PendingPhrase = ""
    $S.LastSpoken = ""
    $S.KnownTotal = 0
    $S.TitleDirty = $true
    $S.LastScreenTitle = ""
}

# --- level select: announce which level, plus its score and ranks ---
# The selection bar here sits on RESUME/RESTART/PRACTICE, so the bar logic alone would
# never mention which level is showing. Watch the big title instead. The same title shows
# the level on Leaderboards, where it announces "Level N, GLOBAL RANKING".
function Update-LevelTitle([System.Drawing.Bitmap]$shot, $bar, $gold) {
    # Stop above the level-selector pip row that sits under the title: included, OCR
    # renders those pips as dashes ("LEVELL-") and loses the digit. Profile only the
    # middle of the screen, where the centred title actually sits - across the full width
    # a single changed digit does not move any bucket enough.
    $titleTop = [int]($shot.Height * 0.03)
    $titleBot = [int]($shot.Height * 0.14)
    $titleProf = [ThumperVision]::TextProfile($shot, $titleTop, $titleBot,
                                              [int]($shot.Width * 0.30), [int]($shot.Width * 0.70))
    $titleChanged = $false
    if (-not $S.LastTitleProfile) {
        $titleChanged = $true
    } else {
        $tmax = 0
        for ($i = 0; $i -lt $titleProf.Length; $i++) {
            $d = [math]::Abs($titleProf[$i] - $S.LastTitleProfile[$i])
            if ($d -gt $tmax) { $tmax = $d }
        }
        $titleChanged = ($tmax -ge 25)
    }
    $S.LastTitleProfile = $titleProf

    # Level select and Leaderboards can show the identical "LEVEL N" title pixels - same
    # text, same position - so going from one screen to the other at the same level number
    # moves nothing in the title profile. Force a re-check whenever which selection widget
    # is on screen flips, since that alone proves the screen changed.
    $widgetKind = if ($bar[0] -ge 0) { "bar" } elseif ($gold[0] -ge 0) { "gold" } else { "none" }
    if ($widgetKind -ne $S.LastWidgetKind) { $titleChanged = $true }
    $S.LastWidgetKind = $widgetKind

    # A fresh title change gets a fresh retry budget. Without the reset, failed reads on
    # one level eat the allowance for the next, and paging quickly leaves later levels
    # unannounced.
    if ($titleChanged) {
        $S.TitleAt = Get-Date; $S.TitlePending = $true; $S.TitleTries = 0; $S.TitleDirty = $true
    }
    if (-not $S.TitlePending -or ((Get-Date) - $S.TitleAt).TotalMilliseconds -lt 350) { return }

    $S.TitlePending = $false
    $titleText = ""
    $box = Get-TitleBox $shot
    if ($box) { $titleText = Read-Strip $shot $box.Top $box.Bot $box.Left $box.Right }
    if ($Verbose) { Write-Host "[title] '$titleText'" }

    if ($titleText -match 'LEVEL\s*(\d+)') {
        $lvNum = [int]$Matches[1]

        # Level select and Leaderboards share the same "LEVEL N" title, so the title alone
        # cannot tell them apart - and announcing the save-file level summary on the
        # leaderboard would be plain wrong. Level select always has the red bar; the
        # leaderboard never does, and names its mode underneath the level pips ("GLOBAL
        # RANKING"). Read that line to be sure, since the board is still "LOADING" when
        # the title lands.
        $mode = ""
        if ($bar[0] -lt 0) { $mode = Read-BandText $shot 0.19 0.26 }

        if ($mode -match 'RANK') {
            $S.TitleTries = 0
            $boardKey = "$lvNum|$mode"
            if ($boardKey -ne $S.LastBoardKey) {
                $S.LastBoardKey = $boardKey
                $phrase = "Level $lvNum, $mode"
                Write-Host "-> $phrase"
                Say $phrase
                $S.LastSpoken = ""
                $S.KnownTotal = 0
            }
        } elseif ($bar[0] -ge 0) {
            # Level select - it is the screen with the red bar. Requiring the bar matters:
            # without it, a leaderboard caught mid-load (no readable mode line yet) fell in
            # here and the real "Level N, GLOBAL RANKING" was suppressed as a duplicate once
            # it actually loaded.
            $S.TitleTries = 0
            $S.LastBoardKey = ""
            # Gated on its own tracker so checking Level 1's leaderboard and then returning
            # to Level 1's select screen doesn't look like "no change" and silently suppress
            # the summary - see notes/session-2026-09-27.
            if ($lvNum -ne $S.LastLevelSummary) {
                $S.LastLevelSummary = $lvNum
                $summary = Format-LevelSummary $lvNum
                if ($summary) {
                    Write-Host "-> $summary"
                    Say $summary
                    # The bar row (RESTART etc) is unchanged across levels; clearing this
                    # lets it be re-announced after the summary - queued behind it, since
                    # that row is read ~0.15s later and used to cut the summary off.
                    $S.LastSpoken = ""
                    $S.QueueRowUntil = (Get-Date).AddMilliseconds(800)
                    $S.KnownTotal = 0
                }
            }
        } elseif ($S.TitleTries -lt 8) {
            # A LEVEL title with no bar and no mode line yet: the leaderboard shows LOADING
            # for a moment after paging to another level. Come back and look again instead
            # of giving up, or that level change is never announced at all.
            $S.TitleTries++
            $S.TitleAt = Get-Date
            $S.TitlePending = $true
        } else {
            $S.TitleTries = 0
        }
    } elseif ($titleText) {
        $S.TitleTries = 0
        $S.LastLevelSummary = 0
        $S.LastBoardKey = ""
    } elseif ($gold[0] -ge 0 -and $S.TitleTries -lt 8) {
        # An empty title read on the Leaderboards screen is a failed OCR, not a state worth
        # acting on: the title is white text over an animated background and intermittently
        # comes back blank. With no retry here the level change is never announced at all.
        $S.TitleTries++
        $S.TitleAt = Get-Date
        $S.TitlePending = $true
    } else {
        $S.TitleTries = 0
    }
}

# --- Leaderboards or Restart-from-checkpoint: a gold outline, not the red bar ---
# Same settle-then-confirm gating as the bar path: the box slides between rows and the
# whole list slides when the page scrolls, and a read taken mid-slide returns a smeared or
# half-scrolled row.
function Invoke-GoldPoll([System.Drawing.Bitmap]$shot, $gold) {
    $prof = [ThumperVision]::TextProfile($shot, $gold[0], $gold[1])
    if (Test-SelectionChanged $gold[0] $prof 0) {
        $S.ChangeAt = Get-Date; $S.PendingRead = $true; $S.PendingTries = 0
    }

    # Heartbeat re-read. On the checkpoint list the gold box never moves - the list scrolls
    # under it - and "LEVEL 1-3" vs "LEVEL 1-4" differ by one digit, too little for the
    # profile test. Caught 2026-09-28: a single Up press with 2 seconds of quiet either side
    # was never announced. Re-reading every 250ms while the box sits still costs one OCR
    # call; an unchanged row matches LastSpoken and is not repeated.
    if (-not $S.PendingRead -and ((Get-Date) - $S.GoldReadAt).TotalMilliseconds -ge 250) {
        $S.PendingRead = $true
        $S.PendingTries = 0
        $S.ChangeAt = [DateTime]::MinValue
    }
    if (-not $S.PendingRead -or ((Get-Date) - $S.ChangeAt).TotalMilliseconds -lt $SettleMs) { return }

    $S.PendingRead = $false
    $S.GoldReadAt = Get-Date
    $phrase = Read-GoldRow $shot $gold[0] $gold[1]
    if ($Verbose) { Write-Host ("[gold {0}-{1}] '{2}'" -f $gold[0], $gold[1], $phrase) }
    if (-not $phrase) {
        # An incomplete read (no score yet) returns nothing. Without an explicit retry the
        # row would stay silent until something else on screen changed, which on a still
        # list is never.
        if ($S.PendingTries -lt 4) {
            $S.PendingTries++
            $S.ChangeAt = Get-Date
            $S.PendingRead = $true
        }
        return
    }

    $key = ($phrase -replace '\s', '').ToUpperInvariant()
    if ($key -eq $S.LastSpoken) { return }
    $S.PendingTries++
    # A clean numbered checkpoint read is trusted without the usual second agreeing read:
    # 76 of 76 reads were exact in a verbose run (2026-09-28), and the confirm step cost
    # ~0.5s per row - enough that pressing again before it finished skipped the row. A
    # mid-scroll crop does not match this strict pattern.
    $cleanCheckpoint = $phrase -match '^Level \d+, checkpoint \d+$'
    if ($key -ne $S.PendingPhrase -and $S.PendingTries -lt 4 -and -not $cleanCheckpoint) {
        if ($Verbose) { Write-Host "   (unconfirmed: $phrase)" }
        $S.PendingPhrase = $key
        $S.ChangeAt = Get-Date
        $S.PendingRead = $true
        return
    }

    $S.LastSpoken = $key
    $S.PendingPhrase = ""
    $S.PendingTries = 0
    # On the checkpoint screen, add that checkpoint's own section rank and points.
    if ($phrase -match '^Level (\d+), checkpoint (\d+)$') {
        $detail = Format-CheckpointSection ([int]$Matches[1]) ([int]$Matches[2])
        if ($detail) { $phrase = "$phrase, $detail" }
    }
    Write-Host "-> $phrase"
    Say $phrase
    # Paging to another level always drops the selection back to rank 1, so this is the
    # moment to make sure the level itself was announced. The title's pixel profile alone
    # is not a reliable trigger: between two levels only one digit changes. Re-checking is
    # cheap and LastBoardKey stops any repeat.
    if ($phrase -match '^rank 1,') {
        $S.TitleAt = Get-Date
        $S.TitlePending = $true
        $S.TitleTries = 0
    }
}

# Read the selected red-bar row: label, value (OCR'd, or measured for a pip slider), and
# whether this is the Controls screen, which lays its rows out differently.
function Read-BarRow([System.Drawing.Bitmap]$shot, $bar, [int]$top, [int]$bot) {
    # Settings rows split into label and value. Read them separately, and measure the
    # value if it is a pip slider rather than OCRing it.
    $split = Get-RowSplit $shot $bar[0] $bar[1]
    $value = ""
    $slider = $null
    if ($split) {
        $text = Read-Strip $shot $top $bot $split.LabelStart $split.LabelEnd
        if (-not $text) { $text = Read-StripTiled $shot $top $bot $split.LabelStart $split.LabelEnd }
        $slider = Get-SliderValue $shot $bar[0] $bar[1] $split.GroupStart
        if ($slider) {
            $value = "slider set to {0}, range 1 to {1}" -f $slider.Value, $slider.Total
        } else {
            $value = Read-Strip $shot $top $bot $split.ValueStart $split.ValueEnd
        }
    } else {
        $text = Read-Strip $shot $top $bot 0 0
    }

    # The Controls screen's rows (label far-left, value far-right with icon glyphs mixed
    # in) do not fit the label/value split above at all - see Read-ControlsValue's own
    # comment. Detected off the label text itself, since every row on this screen has one
    # of these exact labels and nothing on any other screen does.
    $label = $text.Trim().ToUpperInvariant()
    $isControlsScreen = $label -match '^(ACTION|UP|LEFT|DOWN|RIGHT|QUICK RESTART|SELECT|RESTORE DEFAULTS)$'
    if ($isControlsScreen -and $label -ne 'RESTORE DEFAULTS') {
        $value = Read-ControlsValue $shot $bar[0] $bar[1]
    }
    return [pscustomobject]@{
        Text = $text; Value = $value; Slider = $slider; Split = $split
        IsControlsScreen = $isControlsScreen
    }
}

# --- every other menu: the red highlight bar ---
function Invoke-BarPoll([System.Drawing.Bitmap]$shot, $bar) {
    $center = [int](($bar[0] + $bar[1]) / 2)
    $half = [int]($shot.Height * 0.028)
    $top = [math]::Max(0, $center - $half)
    $bot = [math]::Min($shot.Height - 1, $center + $half)
    $prof = [ThumperVision]::TextProfile($shot, $bar[0], $bar[1])

    # The bar physically moves to the selected row, so its position is the cleanest change
    # signal; the profile catches the rest (same row, different text, e.g. a submenu opening
    # over the same layout). A few pixels of tolerance: the bar's detected top edge flickers
    # by 1px between frames (784/785, 2026-09-29), and counting that as a move restarted
    # the settle wait on every poll - LEADERBOARDS was never read at all.
    # The bar slides between rows rather than jumping, so reading the instant it starts
    # moving catches a smeared mid-animation frame: wait for it to hold still first.
    if (Test-SelectionChanged $bar[0] $prof 3) {
        $S.ChangeAt = Get-Date; $S.PendingRead = $true; $S.PendingTries = 0
        $S.FollowUps = 0; $S.IsFollowUp = $false
    }
    if (-not $S.PendingRead -and $S.FollowUps -gt 0 -and (Get-Date) -ge $S.FollowUpAt) {
        $S.PendingRead = $true
        $S.IsFollowUp = $true
        $S.ChangeAt = [DateTime]::MinValue
    }
    if (-not $S.PendingRead -or ((Get-Date) - $S.ChangeAt).TotalMilliseconds -lt $SettleMs) { return }
    $S.PendingRead = $false

    $row = Read-BarRow $shot $bar $top $bot
    $text = $row.Text; $value = $row.Value
    if ($Verbose) { Write-Host ("{4} [bar {0}-{1}] '{2}' / '{3}'" -f $bar[0], $bar[1], $text, $value, (Get-Date -Format "ss.fff")) }
    if (-not ($text -or $value) -or $text.Length -gt 48) { return }

    if ($row.IsControlsScreen) {
        $pos = Get-MenuPosition $shot $center 0.15 0.85
    } else {
        $pos = Get-MenuPosition $shot $center
    }

    # Rows whose value was OCR'd ("1920X1080", "4X") need two agreeing reads: a first read
    # of RESOLUTION came back "1920xm080" (2026-09-29). Labels alone and measured sliders
    # are reliable on the first read - and so is a row and value already confirmed this
    # session. Whether this read's count matches one already confirmed is taken before
    # the update below changes KnownTotal.
    $valueIsOcr = $value -and -not $row.Slider
    $seenKey = (("$text, $value") -replace '\s', '').ToUpperInvariant()
    $valueTrusted = -not $valueIsOcr -or $S.ConfirmedValues.ContainsKey($seenKey)
    $totalConfirmed = $pos -and $S.KnownTotal -gt 0 -and $pos.Total -eq $S.KnownTotal -and $valueTrusted
    $undercount = $false
    if ($pos) {
        if ($pos.Total -gt $S.KnownTotal) {
            $S.KnownTotal = $pos.Total
        } elseif ($pos.Total -lt $S.KnownTotal) {
            # Fewer rows than a total already confirmed on this screen - background art
            # bleeding into the row scan, not a real change. Don't speak a total known to be
            # wrong. The usual cause is the previous row's highlight still fading out (seen
            # 2026-09-29: OPTIONS counted "of 3" on the main menu), so the row is read again
            # before settling for the label alone.
            $pos = $null
            $undercount = $true
        }
    }

    $phrase = $text
    if ($value) { $phrase = if ($text) { "$text, $value" } else { $value } }
    if ($pos) { $phrase += ", item {0} of {1}" -f $pos.Index, $pos.Total }
    if ($text -and $value) { $S.LabelsWithValue[$text.Trim().ToUpperInvariant()] = $true }
    if (-not $totalConfirmed) { $S.ScreenFresh = $true }
    # Compare on a whitespace-stripped key. OCR alternates between "1920X1280" and
    # "1920X 1280" on the same row, and comparing raw text meant two reads never agreed.
    $key = ($phrase -replace '\s', '').ToUpperInvariant()

    if ($S.IsFollowUp) {
        # A follow-up re-read of the row just announced. Speak again only if it is the same
        # row and now has the value, position or higher total the announcement lacked -
        # anything else (OCR jitter) stays quiet.
        $S.IsFollowUp = $false
        $S.FollowUps--
        $S.FollowUpAt = (Get-Date).AddMilliseconds(350)
        $gained = ($value -and -not $S.AnnouncedValue) -or ($pos -and -not $S.AnnouncedPos) -or
                  ($pos -and $pos.Total -gt $S.AnnouncedTotal)
        if ($key -ne $S.LastSpoken -and $text -eq $S.AnnouncedText -and $gained) {
            $S.LastSpoken = $key
            $S.FollowUps = 0
            Write-Host "-> $phrase (follow-up)"
            Say $phrase
        }
        return
    }
    if ($key -eq $S.LastSpoken) { return }

    # Screen transitions slide the whole list, so a single read taken mid-slide sees a
    # partial menu and yields a wrong count ("2 of 2") - a new screen is only spoken once
    # two consecutive reads agree. Once its row count is confirmed, a read that matches it
    # is moving within a settled list, so it is spoken straight away: pressing again before
    # a second read finished used to skip rows. OCR is not perfectly repeatable, so after a
    # few tries the latest read is said rather than skipping the row. Also retry a read
    # whose label came back empty: Controls' UP was once announced as just "w" (2026-09-29).
    $S.PendingTries++
    $retry = ($undercount -or ($row.Split -and -not $text)) -and $S.PendingTries -lt 4
    $ready = -not $retry -and ($key -eq $S.PendingPhrase -or $S.PendingTries -ge 4 -or $totalConfirmed)

    # The title, only on a new screen. The main menu's animated background keeps TitleDirty
    # set and its logo never OCRs as a title, so reading on every row there wasted an OCR
    # call per key press. A title still sliding in reads empty - rows are confirmed fast
    # enough to beat it (Controls, 2026-09-29) - so an empty read holds the row back for up
    # to two more polls first.
    $screenTitle = ""
    if ($ready -and $S.TitleDirty -and $S.ScreenFresh) {
        $screenTitle = Read-ScreenTitle $shot $bar[0]
        if (-not $screenTitle -and $S.TitleWaits -lt 2) { $S.TitleWaits++; $ready = $false }
    }
    if (-not $ready) {
        if ($Verbose) { Write-Host "   (unconfirmed: $phrase)" }
        $S.PendingPhrase = $key
        $S.ChangeAt = Get-Date
        $S.PendingRead = $true
        return
    }

    if ($valueIsOcr) { $S.ConfirmedValues[$seenKey] = $true }
    $S.LastSpoken = $key
    $S.PendingPhrase = ""
    $S.PendingTries = 0
    if ($S.TitleDirty -and $S.ScreenFresh) {
        $S.TitleDirty = $false
        $S.TitleWaits = 0
        if ($screenTitle -and $screenTitle -ne "-" -and $screenTitle -ne $S.LastScreenTitle) {
            $S.LastScreenTitle = $screenTitle
            $sep = if ($screenTitle -match '[?!]$') { " " } else { ". " }
            $phrase = "$screenTitle$sep$phrase"
        }
    }
    $wasFresh = $S.ScreenFresh
    $S.ScreenFresh = $false
    Write-Host "-> $phrase"
    # Only the re-read straight after a level summary is queued behind it; a later key
    # press interrupts as usual.
    Say $phrase -Queue:((Get-Date) -lt $S.QueueRowUntil)
    $S.QueueRowUntil = [DateTime]::MinValue

    # Some values are drawn a moment after their row's label - MSAA's "4X" was missing from
    # a first read taken as soon as the bar landed (2026-09-29) - and a count can be
    # withheld as an undercount. Re-read the row up to twice so the complete version is
    # still said. Also after the first row of a new screen: a menu still fading in can give
    # two agreeing reads with a row missing (main menu "PLAY, item 1 of 3"), and the re-read
    # then corrects the count. Otherwise only for rows known to have a value, or with no
    # position, so plain rows cost no extra OCR.
    $S.AnnouncedText = $text
    $S.AnnouncedValue = [bool]$value
    $S.AnnouncedPos = [bool]$pos
    $S.AnnouncedTotal = if ($pos) { $pos.Total } else { 0 }
    $knownValued = $text -and $S.LabelsWithValue.ContainsKey($text.Trim().ToUpperInvariant())
    $S.FollowUps = if ((-not $pos) -or ($knownValued -and -not $value) -or $wasFresh) { 2 } else { 0 }
    $S.FollowUpAt = (Get-Date).AddMilliseconds(350)

    # Level select and the main menu both use this same red bar, and the title-band change
    # detector cannot be trusted to notice the difference: on the main menu the animated
    # background in that band can jitter continuously, so the title is never re-read and
    # the level-summary memory never gets cleared there. A confirmed row that is NOT one of
    # level select's own proves we have left it - returning to the same level later then
    # announces its summary again.
    if ($text -and ($text.Trim().ToUpperInvariant() -notmatch '^(RESUME|RESTART|PRACTICE|START)$')) {
        $S.LastLevelSummary = 0
    }
}
