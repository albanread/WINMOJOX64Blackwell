# check-keys.ps1 -- the keyboard, pressed for real.
#
# The gap this fills: every other suite drives Griddle through the agent
# verbs, which reach the same functions the keys do but never touch the key
# handler itself. Two bugs lived behind that gap. Ctrl+F5 was a dead key for
# as long as the guide has told people to press it -- the handler existed,
# but an unconditional `return 0` in the Ctrl block above swallowed the
# keystroke first. And F12 discarded whatever it was told, so a person who
# pressed it before the language server was ready got no answer and no
# reason.
#
# Neither could be caught by sending WM_KEYDOWN with SendMessage: the
# handler reads modifier state with GetKeyState, which only real input sets.
# So this foregrounds the window and uses keybd_event, the way a keyboard
# does. That makes it the one suite that needs an interactive desktop; it
# says so and skips rather than failing when it cannot have one.
#
#   .\tools\check-keys.ps1
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\griddle.exe')
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$results = @()
function Record($name, $verdict, $detail) {
    $script:results += [pscustomobject]@{ Name = $name; Verdict = $verdict }
    Write-Host ("  {0} {1}  {2}" -f $name.PadRight(22), $verdict, $detail)
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Keys {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
}
'@

$VK = @{ CONTROL = 0x11; SHIFT = 0x10; F5 = 0x74; F12 = 0x7B }
function Press([int]$key, [int[]]$modifiers = @()) {
    foreach ($m in $modifiers) { [Keys]::keybd_event([byte]$m, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 60 }
    [Keys]::keybd_event([byte]$key, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Keys]::keybd_event([byte]$key, 0, 2, [IntPtr]::Zero)
    foreach ($m in $modifiers) { [Keys]::keybd_event([byte]$m, 0, 2, [IntPtr]::Zero) }
    Start-Sleep -Milliseconds 250
}
function Ask([string]$cmd) { (& "$repo\tools\griddle-cmd.ps1" $cmd) -join "`n" }

Write-Host "== key check =="
if (-not (Test-Path $Exe)) { throw "not built: $Exe" }

# A small file, so the language server is ready in seconds rather than the
# minute a five-thousand-line one takes.
$work = Join-Path $env:TEMP ("griddle-keys-{0}" -f (Get-Random))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $false
$subject = Join-Path $work 'main.mojo'
[System.IO.File]::WriteAllText($subject, @"
def helper() -> Int:
    return 7


def main():
    print("value", helper())
"@.Replace("`r`n", "`n"), $utf8)

$hwndFile = Join-Path $env:TEMP 'griddle.hwnd'
Remove-Item $hwndFile -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $Exe -ArgumentList '--no-session', '--open', "`"$subject`"" -PassThru
try {
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $hwndFile)) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path $hwndFile)) { throw "the window never reported its handle" }
    Start-Sleep -Milliseconds 1200
    $hwnd = [IntPtr][long](Get-Content $hwndFile -Raw).Trim()

    [Keys]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 700
    if ([Keys]::GetForegroundWindow() -ne $hwnd) {
        Record 'foreground' 'SKIP' 'another window holds the foreground; keys cannot be sent'
        Write-Host ""
        Write-Host "key checks skipped: this suite needs an interactive desktop"
        exit 0
    }
    Record 'foreground' 'PASS' 'the editor has the keyboard'

    # F12 goes first, on a quiet editor. Ctrl+F5 below leaves a
    # compiler running for several seconds, and its output arrives on
    # the same timer that applies language-server answers -- asking
    # for a definition behind that tests two things and blames the
    # wrong one.
    # ---- F12: go to definition ------------------------------------------
    # The caret is put on the call to `helper` on the last line, and the
    # definition is on the first, so a jump is unambiguous.
    Ask 'lsp wait 60000' | Out-Null
    # Column 20 is the 'h' of helper; 19 is the space before it, and the
    # server answers about the token under the position, not beside it.
    Ask 'goto 6:20' | Out-Null
    $before = Ask 'caret'
    Press $VK.F12
    # Ten seconds, not four: an empty first answer means the server has not
    # finished reading the file, and the editor asks again -- up to three
    # more times, each costing a round trip.
    Start-Sleep -Seconds 10
    $after = Ask 'caret'
    if ($after -match 'line=0') {
        Record 'f12-jumps' 'PASS' "caret moved to the definition ($($after -replace '\s+',' '))"
    } else {
        Record 'f12-jumps' 'FAIL' "caret did not move: $($after -replace '\s+',' ')"
    }
    # ---- Ctrl+F5: run without debugging ---------------------------------
    Press $VK.F5 @($VK.CONTROL)
    Start-Sleep -Seconds 5
    $out = Ask 'output'
    if ($out -match 'mojo\.exe|exit \d') {
        Record 'ctrl-f5-runs' 'PASS' 'the run reached the output pane'
    } else {
        Record 'ctrl-f5-runs' 'FAIL' 'Ctrl+F5 produced no run'
    }

} finally {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host ("{0} key checks: {1} passed, {2} failed" -f $results.Count,
    (@($results | Where-Object Verdict -eq 'PASS').Count), $bad)
if ($bad -gt 0) { exit 1 }
exit 0
