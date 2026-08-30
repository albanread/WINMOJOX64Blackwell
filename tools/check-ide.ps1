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

# ---- summary ---------------------------------------------------------------
$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host ("{0} checks: {1} passed, {2} failed" -f `
    $results.Count, (@($results | Where-Object Verdict -eq 'PASS').Count), $bad)
if ($bad -gt 0) { exit 1 }
exit 0
