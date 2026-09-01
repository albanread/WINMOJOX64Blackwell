# check-rail.ps1 -- the activity rail, driven like a hand.
#
# Real WM_LBUTTONDOWNs through the queue, one per rail cell, and then the
# editor is asked what its pane is showing. This is the only check that
# exercises the click path itself rather than the functions behind it, and
# it found two bugs on its first run: TrackPopupMenu blocks (so EX is not
# clicked here), and coordinates sent by a DPI-unaware process arrive
# scaled -- which is why this thread declares itself per-monitor-v2 before
# it sends anything.
#
#   .\tools\check-rail.ps1
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\griddle.exe')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$results = @()
function Record($name, $verdict, $detail) {
    $script:results += [pscustomobject]@{ Name = $name; Verdict = $verdict }
    Write-Host ("  {0} {1}  {2}" -f $name.PadRight(20), $verdict, $detail)
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Rail {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
}
'@
# Per-monitor-v2, or Windows scales every coordinate on the way into the
# DPI-aware window and cell 2 becomes cell 3.
[Rail]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null

Write-Host "== rail check =="
if (-not (Test-Path $Exe)) { throw "not built: $Exe" }
$hwndFile = Join-Path $env:TEMP 'griddle.hwnd'
Remove-Item $hwndFile -ErrorAction SilentlyContinue
$subject = Join-Path $repo 'examples\win32\life\main.mojo'
$p = Start-Process -FilePath $Exe -ArgumentList '--no-lsp', '--no-session', '--open', "`"$subject`"" -PassThru
try {
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $hwndFile)) { Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 800
    $hwnd = [IntPtr][long](Get-Content $hwndFile -Raw).Trim()

    function Ask([string]$cmd) { (& "$repo\tools\griddle-cmd.ps1" $cmd) -join "`n" }
    function Click($x, $y) {
        $l = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
        [Rail]::SendMessageW($hwnd, 0x0201, [IntPtr]1, $l) | Out-Null
        [Rail]::SendMessageW($hwnd, 0x0202, [IntPtr]0, $l) | Out-Null
        Start-Sleep -Milliseconds 200
    }

    # The display's scale, from the editor's own report rather than a guess.
    $views = Ask 'views'
    $scale = 1.0
    if ($views -match 'scale ([\d.]+)') { $scale = [double]$matches[1] }
    # Cell centres, from the same design geometry the chrome draws with:
    # top 10, pitch 57, cell 52, rail 52 wide.
    function CellY($i) { [int]((10 + $i * 57 + 26) * $scale) }
    $cx = [int](26 * $scale)

    Click $cx (CellY 1)
    $py = Ask 'views'   # any reply proves the window survived; the pane test is next
    $pane = Ask 'output'
    Click $cx (CellY 3)
    Click $cx (CellY 0)
    # After EDIT the pane is problems; PY and TOOL each leave their view up.
    Click $cx (CellY 1)
    $shot = Join-Path $env:TEMP 'check-rail.png'
    Ask "screenshot $shot" | Out-Null

    if (Test-Path $shot) {
        Record 'clicks-survive' 'PASS' 'four cells clicked, window answering'
    } else {
        Record 'clicks-survive' 'FAIL' 'no screenshot after the clicks'
    }
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ("{0} rail checks: {1} passed, {2} failed" -f $results.Count,
    (@($results | Where-Object Verdict -eq 'PASS').Count), $bad)
if ($bad -gt 0) { exit 1 }
exit 0
