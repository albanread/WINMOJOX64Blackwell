# check-edit.ps1 -- Griddle edits text, or this fails.
#
# Sprint 1.4's suite, in the shape the Mac team's editing checks take: one
# table, one process per case, one assertion each. A fresh process per case is
# deliberate and cheap -- every check starts from a document in a known state,
# so a case that corrupts something cannot make the next one lie.
#
# Everything is driven through the agent surface, which is the same code the
# keyboard reaches: `type` is what WM_CHAR calls, `move` is what the arrow keys
# call, `backspace` is what backspace calls. A check that passes here is a
# check on what a person gets.
#
#   .\tools\check-edit.ps1
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\griddle.exe')
)

$ErrorActionPreference = 'Continue'
$results = @()

function Record($name, $verdict, $detail) {
    $script:results += [pscustomobject]@{ Name = $name; Verdict = $verdict; Detail = $detail }
    Write-Host ("  {0} {1}  {2}" -f $name.PadRight(28), $verdict, $detail)
}

Write-Host "== edit check =="
if (-not (Test-Path $Exe)) { throw "not built: $Exe" }

# Two fixtures. The ASCII one keeps byte counts predictable; the other exists
# so "delete one character" can be checked against characters that are not one
# byte, one code unit, or one advance wide.
$dir = Join-Path $env:TEMP ("griddle-edit-{0}" -f (Get-Random))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ascii = Join-Path $dir 'fix.txt'
$uni = Join-Path $dir 'uni.txt'
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($ascii, "alpha beta`ngamma delta`nepsilon`n", $utf8)
[System.IO.File]::WriteAllText($uni,
    "$([char]0xD83D)$([char]0xDE00)x`n$([char]0x4E2D)$([char]0x6587)y`n", $utf8)

$TAB = [char]9

function Drive($fixture, $commands) {
    $out = cmd /c "`"$Exe`" --open `"$fixture`" --cmd `"$commands`" 2>&1" | Out-String
    # The startup banner is not an answer; drop it, so a check matching on
    # "^alpha" is not defeated by two lines of provenance.
    return (($out -split "`r?`n") | Where-Object { $_ -notmatch '^griddle: ' }) -join "`n"
}

# name, fixture, commands, expected regex
$cases = @(
    # ---- insertion ------------------------------------------------------
    @{n='insert-at-start'; f='a'; c='type X;;text 1'; w='(?m)^Xalpha beta$'}
    @{n='insert-mid-line'; f='a'; c='caret 0 5;;type X;;text 1'; w='(?m)^alphaX beta$'}
    @{n='insert-at-line-end'; f='a'; c='move end;;type X;;text 1'; w='(?m)^alpha betaX$'}
    @{n='insert-many-chars'; f='a'; c='type hello;;text 1'; w='(?m)^helloalpha beta$'}
    @{n='insert-newline-escape'; f='a'; c='type a\nb;;state'; w='lines=5'}
    @{n='insert-tab-escape'; f='a'; c='type a\tb;;text 1'; w="(?m)^a${TAB}balpha beta$"}
    @{n='insert-moves-caret'; f='a'; c='type abc;;caret'; w='col=3'}
    @{n='insert-sets-dirty'; f='a'; c='type a;;state'; w='dirty=True'}

    # ---- deletion -------------------------------------------------------
    @{n='backspace-mid-line'; f='a'; c='caret 0 5;;backspace;;text 1'; w='(?m)^alph beta$'}
    @{n='backspace-joins-lines'; f='a'; c='caret 1 0;;backspace;;text 1'; w='(?m)^alpha betagamma delta$'}
    @{n='backspace-at-doc-start'; f='a'; c='caret 0 0;;backspace;;state'; w='bytes=31'}
    @{n='delete-mid-line'; f='a'; c='caret 0 5;;delete;;text 1'; w='(?m)^alphabeta$'}
    @{n='delete-joins-lines'; f='a'; c='move end;;delete;;text 1'; w='(?m)^alpha betagamma delta$'}
    @{n='delete-at-doc-end'; f='a'; c='goto 4;;move end;;delete;;state'; w='bytes=31'}
    @{n='backspace-selection'; f='a'; c='move right select;;move right select;;backspace;;text 1'; w='(?m)^pha beta$'}
    @{n='delete-selection'; f='a'; c='move right select;;move right select;;delete;;text 1'; w='(?m)^pha beta$'}
    @{n='backspace-whole-emoji'; f='u'; c='move right;;backspace;;text 1'; w='(?m)^x$'}
    @{n='backspace-whole-cjk'; f='u'; c='goto 2;;move right;;backspace;;text 2'; w="(?m)^$([char]0x6587)y$"}
    @{n='delete-whole-emoji'; f='u'; c='delete;;text 1'; w='(?m)^x$'}
    @{n='delete-after-collapse'; f='a'; c='move right select;;move left;;delete;;text 1'; w='(?m)^lpha beta$'}

    # ---- newline --------------------------------------------------------
    @{n='enter-splits-before'; f='a'; c='caret 0 5;;enter;;text 1'; w='(?m)^alpha$'}
    @{n='enter-splits-after'; f='a'; c='caret 0 5;;enter;;text 2'; w='(?m)^ beta$'}
    @{n='enter-adds-a-line'; f='a'; c='enter;;state'; w='lines=5'}
    @{n='enter-moves-caret'; f='a'; c='caret 0 5;;enter;;caret'; w='line=1 col=0'}
    @{n='enter-at-line-start'; f='a'; c='enter;;text 2'; w='(?m)^alpha beta$'}

    # ---- selection ------------------------------------------------------
    @{n='no-selection-at-start'; f='a'; c='sel'; w='no selection'}
    @{n='select-right'; f='a'; c='move right select;;sel'; w='selection 0:0 to 0:1'}
    @{n='select-left'; f='a'; c='caret 0 3;;move left select;;sel'; w='selection 0:3 to 0:2'}
    @{n='select-down'; f='a'; c='move down select;;sel'; w='selection 0:0 to 1:0'}
    @{n='select-all'; f='a'; c='move all;;sel'; w='selection 0:0 to 3:0'}
    @{n='select-to-line-end'; f='a'; c='move end select;;sel'; w='(?m)^alpha beta$'}
    @{n='type-replaces-selection'; f='a'; c='move right select;;move right select;;type Z;;text 1'; w='(?m)^Zpha beta$'}
    @{n='backwards-selection'; f='a'; c='caret 0 5;;move left select;;move left select;;sel'; w='(?m)^ha$'}
    @{n='move-collapses'; f='a'; c='move right select;;move left;;sel'; w='no selection'}
    @{n='click-collapses'; f='a'; c='move all;;click 400 8;;sel'; w='no selection'}

    # ---- caret movement -------------------------------------------------
    @{n='left-wraps-up'; f='a'; c='caret 1 0;;move left;;caret'; w='line=0 col=10'}
    @{n='right-wraps-down'; f='a'; c='move end;;move right;;caret'; w='line=1 col=0'}
    @{n='up-keeps-column'; f='a'; c='caret 1 5;;move up;;caret'; w='line=0 col=5'}
    @{n='down-keeps-column'; f='a'; c='caret 0 5;;move down;;caret'; w='line=1 col=5'}
    @{n='home'; f='a'; c='caret 0 5;;move home;;caret'; w='col=0'}
    @{n='end'; f='a'; c='move end;;caret'; w='col=10'}
    @{n='goto-line'; f='a'; c='goto 2;;caret'; w='line=1 col=0'}
    @{n='goto-line-and-column'; f='a'; c='goto 2:3;;caret'; w='line=1 col=2'}
    @{n='goto-clamps-past-end'; f='a'; c='goto 9999;;caret'; w='line=3'}
    @{n='left-at-doc-start'; f='a'; c='move left;;caret'; w='line=0 col=0'}
    @{n='right-over-emoji'; f='u'; c='move right;;caret'; w='col=2'}
    @{n='left-over-emoji'; f='u'; c='move right;;move left;;caret'; w='col=0'}

    # ---- undo and redo --------------------------------------------------
    @{n='undo-restores-text'; f='a'; c='type X;;undo;;text 1'; w='(?m)^alpha beta$'}
    @{n='undo-restores-caret'; f='a'; c='caret 0 5;;type X;;undo;;caret'; w='col=5'}
    @{n='redo-reapplies'; f='a'; c='type X;;undo;;redo;;text 1'; w='(?m)^Xalpha beta$'}
    @{n='undo-twice'; f='a'; c='type A;;type B;;undo;;undo;;text 1'; w='(?m)^alpha beta$'}
    @{n='redo-twice'; f='a'; c='type A;;type B;;undo;;undo;;redo;;redo;;text 1'; w='(?m)^ABalpha beta$'}
    @{n='edit-clears-redo'; f='a'; c='type A;;undo;;type B;;state'; w='redo=0'}
    @{n='undo-with-no-history'; f='a'; c='undo'; w='nothing to undo'}
    @{n='redo-with-no-future'; f='a'; c='redo'; w='nothing to redo'}
    @{n='undo-depth-grows'; f='a'; c='repeat 5 type a;;state'; w='undo=5'}
    @{n='undo-a-multiline-edit'; f='a'; c='type a\nb\nc;;undo;;state'; w='lines=4'}
    @{n='undo-restores-bytes'; f='a'; c='type abc;;undo;;state'; w='bytes=31'}

    # ---- document state -------------------------------------------------
    @{n='clean-when-opened'; f='a'; c='state'; w='dirty=False'}
    @{n='revision-advances'; f='a'; c='type a;;state'; w='rev=1'}
    @{n='bytes-grow'; f='a'; c='type abc;;state'; w='bytes=34'}
    @{n='history-is-capped'; f='a'; c='repeat 1200 type a;;state'; w='undo=1000'}
)

foreach ($c in $cases) {
    $fixture = if ($c.f -eq 'u') { $uni } else { $ascii }
    $out = Drive $fixture $c.c
    if ($out -match $c.w) {
        Record $c.n 'PASS' ''
    } else {
        $first = @(($out -split "`n") | Where-Object { $_.Trim() })[0]
        Record $c.n 'FAIL' "wanted /$($c.w)/, got: $first"
    }
}

# ---- what a thousand levels of undo actually costs --------------------------
# The claim the sprint makes is a memory claim, so it wants a number from the
# operating system rather than a calculation by the thing being measured. Run
# it against the big synthetic document, because the interesting question is
# whether the cost tracks the size of the *edit* or the size of the document --
# a history that copied the document would be fourteen gigabytes here.
$out = (cmd /c "`"$Exe`" --lines 250000 --cmd `"mem;;repeat 1000 type a;;state;;mem`" 2>&1" | Out-String)
$mem = @([regex]::Matches($out, 'committed (\d+) bytes'))
if ($mem.Count -lt 2) {
    Record 'history-cost' 'FAIL' 'no memory reading came back'
} elseif ($out -notmatch 'undo=1000') {
    Record 'history-cost' 'FAIL' 'the history did not reach 1000'
} else {
    $grew = [int64]$mem[1].Groups[1].Value - [int64]$mem[0].Groups[1].Value
    $each = [int]($grew / 1000)
    # One 4 KB rope leaf plus the path back to the root, per edit. The ceiling
    # is generous, but it is a ceiling: anything that starts copying the
    # document instead of sharing it goes straight through it.
    if ($each -gt 0 -and $each -lt 16384) {
        Record 'history-cost' 'PASS' `
            "1000 levels on a 14 MB document: $([int]($grew/1024)) KB, $each bytes an edit"
    } else {
        Record 'history-cost' 'FAIL' "$each bytes an edit, wanted under 16384"
    }
}

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue

$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host ("{0} checks: {1} passed, {2} failed" -f `
    $results.Count, (@($results | Where-Object Verdict -eq 'PASS').Count), $bad)
if ($bad -gt 0) { exit 1 }
exit 0
