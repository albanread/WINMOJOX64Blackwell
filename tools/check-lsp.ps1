# check-lsp.ps1 -- the language server, from inside the editor.
#
# Separate from check-ide.ps1 because every case here spawns a compiler and
# waits for it to parse: about a second each, against the tens of milliseconds
# the rest of that suite runs in. Keeping them apart means the fast suite stays
# fast and this one can be run when the server or the client has changed.
#
# Skips cleanly if the server is not built, rather than failing: not everyone
# working on the editor has built the compiler tools.
#
#   ./bazelw.cmd build //KGEN/tools/mojo-lsp-server
#   .\tools\check-lsp.ps1
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\griddle.exe')
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$results = @()

function Record($name, $verdict, $detail) {
    $script:results += [pscustomobject]@{ Name = $name; Verdict = $verdict; Detail = $detail }
    Write-Host ("  {0} {1}  {2}" -f $name.PadRight(24), $verdict, $detail)
}

Write-Host "== lsp check =="
if (-not (Test-Path $Exe)) { throw "not built: $Exe" }

$server = Join-Path $repo 'bazel-bin\KGEN\tools\mojo-lsp-server\mojo-lsp-server.exe'
if (-not (Test-Path $server)) {
    Write-Host "  the language server is not built; skipping"
    Write-Host "  ./bazelw.cmd build //KGEN/tools/mojo-lsp-server"
    exit 0
}

# A file with two mistakes in it, using the COM surface, so the server has to
# parse what this repository actually writes rather than a toy.
$dir = Join-Path $env:TEMP ("griddle-lsp-{0}" -f (Get-Random))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$broken = Join-Path $dir 'broken.mojo'
[System.IO.File]::WriteAllText($broken, @'
from std.sys.com import Com


def main() raises:
    var target = Com[StaticString("IDropTarget")](borrowed=0)
    var a = definitely_not_a_function()
    var b = also_not_a_thing()
    _ = target
    _ = a
    _ = b
'@.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))

$clean = Join-Path $dir 'clean.mojo'
[System.IO.File]::WriteAllText($clean, @'
def main() raises:
    var x = 1
    print(x)
'@.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))

function Ask($file, $command) {
    $raw = cmd /c "`"$Exe`" --open `"$file`" --cmd `"$command`" 2>&1" | Out-String
    # Drop the server's own log lines and the startup banner: what is being
    # checked is the editor's answer, not the transcript underneath it.
    return (($raw -split "`r?`n") |
        Where-Object { $_ -notmatch '^(griddle: |I\[|D\[|E\[|Parsed |Failed to initialize Crashpad)' }) -join "`n"
}

# 1. The server starts from inside the editor, and finishes its handshake.
$out = Ask $clean 'lsp wait 25000'
if ($out -match 'ready') {
    Record 'lsp-starts' 'PASS' 'spawned from the editor and handshook'
} else {
    Record 'lsp-starts' 'FAIL' (($out -split "`n" | Where-Object { $_.Trim() })[0])
}

# 2. A clean file produces no issues -- so "no issues" means the server looked
# and found nothing, not that nothing was asked.
if ($out -match 'no issues') {
    Record 'lsp-clean-file' 'PASS' 'a file that compiles reports nothing'
} else {
    Record 'lsp-clean-file' 'FAIL' 'a clean file produced diagnostics'
}

# 3. Both mistakes come back, on the right lines, from a COM-using file.
$out = Ask $broken 'lsp wait 25000;;issues'
$errors = @([regex]::Matches($out, "(?m)^error (\d+):(\d+)\s+(.+)$"))
if ($errors.Count -eq 2 -and
    $errors[0].Groups[1].Value -eq '6' -and $errors[1].Groups[1].Value -eq '7') {
    Record 'lsp-diagnostics' 'PASS' `
        "two errors, lines $($errors[0].Groups[1].Value) and $($errors[1].Groups[1].Value)"
} else {
    Record 'lsp-diagnostics' 'FAIL' "got $($errors.Count): $(($out -split "`n" | Where-Object { $_ -match 'error' }) -join '; ')"
}

# 4. The message is the compiler's own, not a summary of it.
if ($out -match "use of unknown declaration 'definitely_not_a_function'") {
    Record 'lsp-message' 'PASS' "the compiler's own wording reaches the pane"
} else {
    Record 'lsp-message' 'FAIL' 'the diagnostic text did not survive'
}

# 5. Jumping to an issue by number lands the caret on its line and column.
$out = Ask $broken 'lsp wait 25000;;issues 2;;caret'
if ($out -match 'caret line=6 col=12') {
    Record 'lsp-goto-issue' 'PASS' 'issue 2 put the caret on line 7, column 13'
} else {
    Record 'lsp-goto-issue' 'FAIL' (($out -split "`n" | Where-Object { $_ -match 'caret' })[-1])
}

# 6. And clicking the row in the issues pane does the same thing, through the
# same path a person's mouse takes.
$out = Ask $broken 'lsp wait 25000;;views;;click 300 600;;caret'
if ($out -match 'caret line=5 col=12') {
    Record 'lsp-click-issue' 'PASS' 'a click in the pane landed on the first issue'
} else {
    Record 'lsp-click-issue' 'FAIL' (($out -split "`n" | Where-Object { $_ -match 'caret' })[-1])
}

# 7. A text file gets no server at all. A Mojo language server has nothing to
# say about one, and starting a compiler per opened document is a cost the
# rest of the check suite would pay on every run.
$txt = Join-Path $dir 'plain.txt'
[System.IO.File]::WriteAllText($txt, "just some words`n",
    (New-Object System.Text.UTF8Encoding $false))
$out = Ask $txt 'issues'
if ($out -match 'not running') {
    Record 'lsp-only-for-mojo' 'PASS' 'no server for a .txt document'
} else {
    Record 'lsp-only-for-mojo' 'FAIL' 'a server was started for a text file'
}

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue

$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host ("{0} checks: {1} passed, {2} failed" -f `
    $results.Count, (@($results | Where-Object Verdict -eq 'PASS').Count), $bad)
if ($bad -gt 0) { exit 1 }
exit 0
