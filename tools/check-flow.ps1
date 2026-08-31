# check-flow.ps1 -- the edit-build-diagnose loop, driven from outside.
#
# Sprint 7.1's acceptance: the whole flow driven externally in CI on the
# built app. check-ide.ps1 asks Griddle thirty-seven questions about itself;
# this asks it to do one job from end to end, the way a person does it --
# open a file, break it, watch the compiler complain, be taken to the line,
# fix it, watch it build.
#
# It is a separate script rather than more checks because it is a different
# kind of test. check-ide.ps1 is fast and answers "is anything broken"; this
# spawns compilers and takes the better part of a minute, and answers "does
# the thing the IDE is for still work".
#
#   .\tools\check-flow.ps1
#
# Everything runs through `run-script`, so what CI executes is a file a
# person could have written by hand and can read afterwards. That is the
# point of the verb: the record and the program are the same artefact.
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\griddle.exe')
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$results = @()

function Record($name, $verdict, $detail) {
    $script:results += [pscustomobject]@{ Name = $name; Verdict = $verdict }
    Write-Host ("  {0} {1}  {2}" -f $name.PadRight(20), $verdict, $detail)
}

Write-Host "== flow check =="
if (-not (Test-Path $Exe)) { throw "not built: $Exe" }

# A scratch project of its own, so a failed run cannot leave the repository
# holding a file that does not compile.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("griddle-flow-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$subject = Join-Path $work 'subject.mojo'
$script = Join-Path $work 'flow.griddle'

# Every run asks for `output` after the script. run-script echoes each
# command and its reply into the output pane rather than to stdout -- which
# is right, because that is where a person watching a script sees it and a
# hundred replies do not belong in one return value -- so the pane is asked
# for on the way out. `--no-lsp` throughout: the compiler's diagnostics are
# what this is about, and a language server would only add a second opinion.

# Written without a byte-order mark. Set-Content -Encoding utf8 adds one in
# Windows PowerShell, and mojo.exe refuses a source file that begins with it
# ("error: unexpected character") -- so a subject written the obvious way
# fails to compile for a reason that has nothing to do with the typo this
# check is about. See docs/mojo-traps.md.
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
function WriteText($path, $lines) {
    [System.IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), $utf8NoBom)
}

try {
    # ---- 1. a program with one mistake in it, on a known line ------------
    WriteText $subject @(
        'def main():'
        '    var total = 0'
        '    for i in range(4):'
        '        total += i'
        '    print("total", totl)'      # the typo, line 5
    )

    # ---- 2. the session, as a file a person could have typed -------------
    WriteText $script @(
        '# The edit-build-diagnose loop, replayed.'
        'build'
        'build wait 240000'
    )

    $out = & cmd /c "`"$Exe`" --open `"$subject`" --no-lsp --cmd `"run-script $script;;output`" 2>&1" | Out-String

    if ($out -match 'script (\d+) command') {
        Record 'script-runs' 'PASS' "$($matches[1]) commands replayed from a file"
    } else {
        Record 'script-runs' 'FAIL' 'run-script did not report'
    }

    # The compiler's complaint has to reach the pane, and it has to name the
    # line the mistake is on. A build that fails silently is worse than one
    # that does not run.
    if ($out -match 'subject\.mojo:5') {
        Record 'diagnostic-line' 'PASS' 'the error is reported against line 5'
    } elseif ($out -match 'totl') {
        Record 'diagnostic-line' 'FAIL' 'the error came back without its line'
    } else {
        Record 'diagnostic-line' 'FAIL' 'the compiler said nothing about the typo'
    }

    # ---- 3. the fix, made through the editor, then built again ----------
    # The point of doing it this way rather than rewriting the file from
    # PowerShell: this proves the editor's own edit reaches the disk in the
    # state the compiler then reads.
    WriteText $script @(
        '# Fix it in the editor, save, and build what was saved.'
        'goto 5'
        'find totl'
        'type total'
        'save'
        'build'
        'build wait 240000'
    )

    $out = & cmd /c "`"$Exe`" --open `"$subject`" --no-lsp --cmd `"run-script $script;;output`" 2>&1" | Out-String
    $fixed = (Get-Content $subject -Raw)

    if ($fixed -match 'print\("total", total\)') {
        Record 'edit-reaches-disk' 'PASS' 'the editor saved the fix'
    } else {
        Record 'edit-reaches-disk' 'FAIL' 'the file on disk still has the typo'
    }

    if ($out -match 'exit 0' -and $out -notmatch 'subject\.mojo:\d+:\d+: error') {
        Record 'builds-clean' 'PASS' 'the fixed program compiles'
    } else {
        Record 'builds-clean' 'FAIL' 'it still does not build'
    }

    # ---- 4. and the built program runs -----------------------------------
    WriteText $script @(
        'run'
        'run wait 240000'
    )
    $out = & cmd /c "`"$Exe`" --open `"$subject`" --no-lsp --cmd `"run-script $script;;output`" 2>&1" | Out-String
    if ($out -match 'total 6') {
        Record 'runs' 'PASS' 'the program ran and printed its answer'
    } else {
        Record 'runs' 'FAIL' 'the program did not produce its output'
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host ("{0} flow checks: {1} passed, {2} failed" -f `
    $results.Count, (@($results | Where-Object Verdict -eq 'PASS').Count), $bad)
if ($bad -gt 0) { exit 1 }
exit 0
