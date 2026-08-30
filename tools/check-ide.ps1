# check-ide.ps1 -- Griddle answers, or this fails.
#
# Born in sprint 0.2 with one check and grows one per sprint, never
# shrinking. It drives the IDE the way an agent does rather than the way a
# person does, so every later sprint stays verifiable with nobody at the
# keyboard.
#
#   .\tools\check-ide.ps1
#
# Note on how it talks to Griddle. The commands go through --cmd, which
# sends WM_COPYDATA to Griddle's own window: a self-send dispatches straight
# into the window procedure, so the whole path -- message, handler,
# dispatcher, reply -- is exercised in one process. tools\griddle-cmd.ps1 is
# the same protocol from outside and is what a person or a running agent
# uses; it needs the caller to share a window station with the IDE, which a
# build harness does not always arrange, so the check does not depend on it.
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\griddle.exe')
)

$ErrorActionPreference = 'Continue'
$results = @()

function Record($name, $verdict, $detail) {
    $script:results += [pscustomobject]@{ Name = $name; Verdict = $verdict; Detail = $detail }
    Write-Host ("  {0} {1}  {2}" -f $name.PadRight(24), $verdict, $detail)
}

function Ask($command) {
    # cmd /c so a non-zero exit never becomes a PowerShell exception here;
    # the checks below decide what a bad answer means.
    return (cmd /c "`"$Exe`" --cmd `"$command`" 2>&1" | Out-String)
}

Write-Host "== ide check =="
if (-not (Test-Path $Exe)) { throw "not built: $Exe" }
Write-Host "  exe: $Exe"

# ---- 1. the agent surface round-trips --------------------------------------
$out = Ask 'status'
if ($out -match 'griddle \d+\.\d+\.\d+ hwnd=\d+') {
    Record 'agent-round-trip' 'PASS' 'OK agent round trip'
} else {
    Record 'agent-round-trip' 'FAIL' (($out -split "`n")[-2])
}

# ---- 2. a verb's argument survives the trip --------------------------------
# Distinguishes "something answered" from "our text reached the dispatcher
# and came back", which is the part a transport can quietly get wrong.
$marker = "griddle-check-{0}" -f (Get-Random)
$out = Ask "echo $marker"
if ($out -match [regex]::Escape($marker)) {
    Record 'agent-echo' 'PASS' 'argument survives the round trip'
} else {
    Record 'agent-echo' 'FAIL' 'the echoed text did not come back'
}

# ---- 3. an unknown verb is refused, with words -----------------------------
$out = Ask 'definitely-not-a-verb'
if ($out -match "unknown verb") {
    Record 'agent-unknown-verb' 'PASS' 'refused, as designed'
} else {
    Record 'agent-unknown-verb' 'FAIL' 'an unknown verb was not refused'
}

# ---- 4. the window stays up -------------------------------------------------
# The message loop waits for quit and nothing else. A stray thread-level
# WM_TIMER once closed it within a second of opening, which reads exactly
# like "the loop does not work" -- so the check times the wait rather than
# trusting it.
$t0 = Get-Date
$null = cmd /c "`"$Exe`" --ms 1200 2>&1"
$elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
if ($elapsed -ge 1000) {
    Record 'window-stays-up' 'PASS' "${elapsed}ms for a 1200ms run"
} else {
    Record 'window-stays-up' 'FAIL' "closed after only ${elapsed}ms"
}

# ---- 5. the window survives a resize ---------------------------------------
$out = cmd /c "`"$Exe`" --selftest --ms 300 2>&1" | Out-String
if ($out -match 'alive after resize: True') {
    Record 'window-resize' 'PASS' 'client area changed, window alive'
} else {
    Record 'window-resize' 'FAIL' 'did not survive the resize'
}

# ---- 6. the app photographs itself -----------------------------------------
# PNG magic alone would pass on a truncated file, and a byte count alone
# would pass on garbage, so decode it and check the dimensions are the
# window's own. That is the difference between "a file appeared" and "the
# window was photographed".
$shot = Join-Path $env:TEMP ("griddle-check-{0}.png" -f (Get-Random))
Remove-Item $shot -ErrorAction SilentlyContinue
$out = Ask "screenshot $shot"
if (-not (Test-Path $shot)) {
    Record 'screenshot' 'FAIL' (($out -split "`n")[-2])
} else {
    $bytes = [System.IO.File]::ReadAllBytes($shot)
    $isPng = $bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 `
             -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47
    if (-not $isPng) {
        Record 'screenshot' 'FAIL' 'the file is not a PNG'
    } else {
        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($shot)
        $w = $img.Width; $h = $img.Height
        $img.Dispose()
        if ($w -gt 100 -and $h -gt 100) {
            Record 'screenshot' 'PASS' "PNG decodes, ${w}x${h}, $($bytes.Length) bytes"
        } else {
            Record 'screenshot' 'FAIL' "decoded but implausible: ${w}x${h}"
        }
    }
    Remove-Item $shot -ErrorAction SilentlyContinue
}

# ---- 7. every region of the chrome is laid out -----------------------------
# Asked of the running window rather than recomputed here, so this checks
# the layout instead of a copy of it.
$out = Ask 'views'
$missing = @('rail','sidebar','editor','issues','output','status') |
    Where-Object { $out -notmatch "(?m)^$_ \d+,\d+ \d+x\d+" }
if ($missing.Count -eq 0) {
    Record 'chrome-regions' 'PASS' 'all six regions reported with geometry'
} else {
    Record 'chrome-regions' 'FAIL' "missing: $($missing -join ', ')"
}

# ---- 8. a menu item is invoked by its visible name --------------------------
# The master key: every feature that ever gets a menu item joins the agent
# surface without a verb of its own, so this check protects all of them.
$out = Ask 'menu File > Exit'
if ($out -match 'invoked File > Exit') {
    Record 'menu-by-name' 'PASS' 'File > Exit reached through the live menu'
} else {
    Record 'menu-by-name' 'FAIL' (($out -split "`n")[-2])
}
$out = Ask 'menu Nope > Nothing'
if ($out -match "no menu 'Nope'") {
    Record 'menu-unknown' 'PASS' 'refused, as designed'
} else {
    Record 'menu-unknown' 'FAIL' 'a missing menu was not refused'
}

# ---- 9. the window is a live OLE drop target -------------------------------
# The refcount is the load-bearing number: two means Windows took a
# reference to an object this IDE implemented in Mojo with the `class`
# keyword, and is holding it across the process boundary. The paths a real
# drag carries need Explorer, which is the documented manual half.
$out = Ask 'drop-test'
if ($out -match 'refcount=2' -and $out -match 'DragEnter hr=0' -and $out -match 'Drop hr=0') {
    Record 'drop-target' 'PASS' 'OLE holds it; DragEnter and Drop dispatch'
} elseif ($out -match 'refcount=(\d+)') {
    Record 'drop-target' 'FAIL' "refcount $($matches[1]), wanted 2"
} else {
    Record 'drop-target' 'FAIL' (($out -split "`n")[-2])
}

# ---- 10-13. the text grid ---------------------------------------------------
# All four run against a synthetic quarter-million-line document, because the
# claims being checked are the ones that only a large document can falsify:
# a small file draws every line either way.
function AskBig($command) {
    return (cmd /c "`"$Exe`" --lines 250000 --cmd `"$command`" 2>&1" | Out-String)
}
function Counters($text) {
    # The last counter line an answer contains, as a hashtable. The @() is
    # load-bearing: a single match collapses to a string, and [-1] on a string
    # is its last character, which then matches nothing and looks like an
    # empty answer rather than a bug in this line.
    $line = @($text -split "`n" | Where-Object { $_ -match 'layouts: hits=' })[-1]
    if (-not $line) { return $null }
    $h = @{}
    foreach ($m in [regex]::Matches($line, '(\w+)=(\d+)')) {
        $h[$m.Groups[1].Value] = [int]$m.Groups[2].Value
    }
    return $h
}

# 10. Only the viewport is touched. A 250,001-line document draws a screenful.
$c = Counters (AskBig 'grid')
if ($null -eq $c) {
    Record 'grid-viewport' 'FAIL' 'no counters came back'
} elseif ($c.lines -lt 250000) {
    Record 'grid-viewport' 'FAIL' "document is $($c.lines) lines, wanted 250001"
} elseif ($c.drawn -gt 0 -and $c.drawn -lt 200) {
    Record 'grid-viewport' 'PASS' `
        "$($c.lines) lines, $($c.drawn) drawn -- a screenful, not a document"
} else {
    Record 'grid-viewport' 'FAIL' "drew $($c.drawn) lines of $($c.lines)"
}

# 11. Scrolling one line lays out one line. This is the whole cache claim:
# if it ever stops being true, this number is where it shows.
$c = Counters (AskBig 'grid reset;;scroll 1;;paint;;grid')
if ($null -eq $c) {
    Record 'grid-scroll-reuse' 'FAIL' 'no counters came back'
} elseif ($c.misses -le 2 -and $c.hits -ge 10) {
    Record 'grid-scroll-reuse' 'PASS' `
        "one line scrolled: $($c.hits) reused, $($c.misses) laid out"
} else {
    Record 'grid-scroll-reuse' 'FAIL' `
        "one line scrolled but laid out $($c.misses) (reused $($c.hits))"
}

# 12. Half a screen exposes half a screen. Guards against the cache
# accidentally being right for one line and wrong for anything larger.
$c = Counters (AskBig 'grid reset;;scroll 12;;paint;;grid')
if ($null -eq $c) {
    Record 'grid-scroll-partial' 'FAIL' 'no counters came back'
} elseif ($c.misses -ge 10 -and $c.misses -le 14 -and $c.hits -ge 10) {
    Record 'grid-scroll-partial' 'PASS' `
        "twelve lines scrolled: $($c.hits) reused, $($c.misses) laid out"
} else {
    Record 'grid-scroll-partial' 'FAIL' `
        "twelve lines scrolled: $($c.hits) reused, $($c.misses) laid out"
}

# 13. Neither end can be scrolled past. `1 << 40` is deliberately absurd:
# the answer should be the last line, not the number asked for.
$out = AskBig 'scroll to 999999999;;grid;;scroll to -50;;grid'
$tops = [regex]::Matches($out, 'top=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }
if ($tops.Count -ge 2 -and $tops[0] -eq 250000 -and $tops[1] -eq 0) {
    Record 'grid-clamp' 'PASS' 'clamped to the last line and to the first'
} else {
    Record 'grid-clamp' 'FAIL' "tops were $($tops -join ', '), wanted 250000 then 0"
}

# 14. Scrolling holds the refresh rate. The mean is pinned to the vertical
# blank and says nothing; the dropped count is the claim -- every frame
# arrived on the refresh it was due, on a 14 MB document.
$out = AskBig 'frame 120'
if ($out -match '(\d+) dropped') {
    $dropped = [int]$matches[1]
    $worst = if ($out -match 'worst ([\d.]+) ms') { [double]$matches[1] } else { 0 }
    if ($dropped -eq 0) {
        Record 'grid-frame-budget' 'PASS' `
            "120 scroll frames, none dropped, worst $([math]::Round($worst,1)) ms"
    } else {
        Record 'grid-frame-budget' 'FAIL' "$dropped of 120 frames dropped"
    }
} else {
    Record 'grid-frame-budget' 'FAIL' 'no frame report came back'
}

# ---- 15-16. caret truth -----------------------------------------------------
# A monospaced grid tempts you to answer "where does the caret go" with
# multiplication, and for ASCII that is exactly right. These two check the
# lines where it is wrong: a CJK ideograph is two advances, an emoji is one
# glyph of two UTF-16 units, a combining accent is zero advances and must
# never be a caret stop, and a tab is a jump to a stop rather than a width.
$mixed = Join-Path $env:TEMP ("griddle-mixed-{0}.txt" -f (Get-Random))
[System.IO.File]::WriteAllText($mixed, (@(
    'plain ascii line, arithmetic all the way'
    "mixed: abc $([char]0x4E2D)$([char]0x6587)$([char]0x6587)$([char]0x5B57) def " +
        "$([char]0xD83D)$([char]0xDE00)$([char]0xD83D)$([char]0xDE80) ghi " +
        "$([char]0xE9)$([char]0xE8)$([char]0xEA) jkl"
    "$([char]0x4ECA)$([char]0x65E5)$([char]0x306F)$([char]0x4E16)$([char]0x754C) CJK only"
    "flags $([char]0xD83C)$([char]0xDDEC)$([char]0xD83C)$([char]0xDDE7) and a " +
        "ZWJ $([char]0xD83D)$([char]0xDC69)$([char]0x200D)$([char]0xD83D)$([char]0xDCBB) sequence"
    "tab`there`tand`there"
    "combining: e$([char]0x301) a$([char]0x300) o$([char]0x302)"
) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))

function AskMixed($command) {
    return (cmd /c "`"$Exe`" --open `"$mixed`" --cmd `"$command`" 2>&1" | Out-String)
}

# 15. Every caret stop on every line survives the round trip: the x the caret
# is placed at, clicked a quarter into the glyph that follows, comes back as
# the same stop. Walked by DirectWrite's own cluster lengths, so a stop is
# never the middle of a surrogate pair.
$out = AskMixed 'hittest 0;;hittest 1;;hittest 2;;hittest 3;;hittest 4;;hittest 5'
$stops = ([regex]::Matches($out, ' OK(\r?\n|$)')).Count
$bad = ([regex]::Matches($out, 'MISMATCH')).Count
$fast = ([regex]::Matches($out, 'simple=True')).Count
$slow = ([regex]::Matches($out, 'simple=False')).Count
if ($bad -gt 0) {
    Record 'caret-round-trip' 'FAIL' "$bad of $($stops + $bad) caret stops landed wrong"
} elseif ($stops -lt 100) {
    Record 'caret-round-trip' 'FAIL' "only $stops stops checked; the document did not load"
} elseif ($fast -lt 1 -or $slow -lt 4) {
    Record 'caret-round-trip' 'FAIL' "paths taken: $fast arithmetic, $slow DirectWrite"
} else {
    Record 'caret-round-trip' 'PASS' `
        "$stops stops, none wrong ($fast line by arithmetic, $slow by DirectWrite)"
}

# 16. And a click in real client coordinates lands there too -- the same
# function the window procedure calls on WM_LBUTTONDOWN, so what a person
# gets and what this gets cannot drift apart.
$out = AskMixed 'views;;caret 1 15;;click 443 24'
$textX = if ($out -match '(?m)^text (\d+)') { [int]$matches[1] } else { 0 }
$caretX = if ($out -match 'col=15 x=([\d.]+)') { [double]$matches[1] } else { -1 }
# @() again: a MatchCollection does not take a negative index, and without
# the wrap this line throws rather than failing the check -- which reads, in
# the summary, as a check that was never there.
$landed = @([regex]::Matches($out, 'caret line=(\d+) col=(\d+)'))[-1]
if ($textX -eq 0 -or $caretX -lt 0) {
    Record 'caret-click' 'FAIL' 'the window did not report its text origin'
} elseif ($landed.Groups[1].Value -eq '1' -and $landed.Groups[2].Value -eq '15') {
    Record 'caret-click' 'PASS' `
        "click at x=443 landed on line 1 col 15 (text starts at $textX, caret at $caretX)"
} else {
    Record 'caret-click' 'FAIL' `
        "landed on line $($landed.Groups[1].Value) col $($landed.Groups[2].Value), wanted 1/15"
}
Remove-Item $mixed -ErrorAction SilentlyContinue

# ---- 17-21. the text store ---------------------------------------------------
# Sprint 1.5. `tsf` drives the store through its own vtable with a real sink
# advised, which is what an input method does -- so these check the contract
# TSF actually depends on rather than a simulation of it. What they cannot
# cover is a real IME choosing to make those calls; that half is manual and
# is written down in docs/tsf-manual-check.md.
# A known, small document: the store clamps a read to the caller buffer, so a
# check run against whatever happened to be open cannot tell a correct clamp
# from a short read.
$tsfDoc = Join-Path $env:TEMP ("griddle-tsf-{0}.txt" -f (Get-Random))
[System.IO.File]::WriteAllText($tsfDoc, "alpha beta`ngamma delta`n",
    (New-Object System.Text.UTF8Encoding $false))
$out = (cmd /c "`"$Exe`" --open `"$tsfDoc`" --cmd tsf 2>&1" | Out-String)
Remove-Item $tsfDoc -ErrorAction SilentlyContinue

if ($out -match 'lock-before-sink: refused') {
    Record 'tsf-lock-needs-sink' 'PASS' 'a lock with nowhere to call back is refused'
} else {
    Record 'tsf-lock-needs-sink' 'FAIL' 'a lock was granted with no sink advised'
}

# flags=6 is TS_LF_READWRITE: the lock the store was asked for is the lock the
# sink was called back with, which is the whole of the protocol.
if ($out -match '(?m)^lock: hr=0 session=0' -and $out -match 'flags=6') {
    Record 'tsf-lock-granted' 'PASS' 'read-write lock granted, sink called back inside it'
} else {
    Record 'tsf-lock-granted' 'FAIL' (($out -split "`n" | Where-Object { $_ -match 'lock:' })[0])
}

# The nine-argument GetText, called from inside the lock, reading to the end
# of the document without having asked how long it was.
if ($out -match 'end=(\d+) expected=(\d+) units=(\d+)') {
    $end, $want, $units = [int]$matches[1], [int]$matches[2], [int]$matches[3]
    # The sink asks for 256 units, so a document longer than that must come
    # back clamped -- a store that overruns the caller buffer is the one bug
    # in a text store that corrupts the input method rather than the document.
    $expected = [Math]::Min($want, 256)
    if ($end -eq $want -and $units -eq $expected -and $want -gt 0) {
        Record 'tsf-gettext' 'PASS' "read $units of $want units under the lock"
    } else {
        Record 'tsf-gettext' 'FAIL' "end=$end units=$units, wanted $expected of $want"
    }
} else {
    Record 'tsf-gettext' 'FAIL' 'no read came back from inside the lock'
}

# SetText is how a committed composition arrives. The change report is what
# the input method uses to keep its own idea of the document in step.
if ($out -match 'settext: hr=0 change=0\.\.0->3' -and $out -match 'first line now: TSFalpha') {
    Record 'tsf-settext' 'PASS' 'text committed, change reported as 0..0->3'
} else {
    Record 'tsf-settext' 'FAIL' (($out -split "`n" | Where-Object { $_ -match 'settext' })[0])
}

if ($out -match 'setselection: anchor=1 caret=3') {
    Record 'tsf-selection' 'PASS' 'selection set through the store, read back from the editor'
} else {
    Record 'tsf-selection' 'FAIL' (($out -split "`n" | Where-Object { $_ -match 'setselection' })[0])
}

# 22. No address is laundered through an integer on its way into a call.
# `Int(Pointer(to=x))` erases the origin, so the compiler is no longer told
# that x is read after the call, and dropping its store is then correct. See
# docs/addresses-and-optimization.md. `com_addr` states the fact instead.
# This check is a grep because what it guards is invisible in a debug build,
# so no amount of running the debug binary would ever catch it coming back.
$ideDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'ide'
$offenders = @(Get-ChildItem $ideDir -Filter *.mojo |
    Select-String -Pattern 'Int\(Pointer\(to=' |
    Where-Object { $_.Line -notmatch '^\s*#' })
if ($offenders.Count -eq 0) {
    Record 'no-int-addresses' 'PASS' 'every by-pointer argument stays a pointer'
} else {
    $where = ($offenders | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', '
    Record 'no-int-addresses' 'FAIL' "use com_addr instead: $where"
}

# ---- summary ---------------------------------------------------------------
$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host ("{0} checks: {1} passed, {2} failed" -f `
    $results.Count, (@($results | Where-Object Verdict -eq 'PASS').Count), $bad)
if ($bad -gt 0) { exit 1 }
exit 0
