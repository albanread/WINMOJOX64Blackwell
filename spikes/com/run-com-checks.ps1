# The COM spike suite: the must-pass half runs, the must-fail half is the
# interesting half. Every sNN must compile, run and print PASS; every fNN
# must FAIL TO COMPILE -- a must-fail that compiles is a broken check, not a
# lucky day. s09 additionally requires cl.exe, because the metadata can say
# what and where but only a foreign compiler confirms how the bytes pass.
#
# Run from the repository root:  .\spikes\com\run-com-checks.ps1

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repo

$mojo = Join-Path $repo 'bazel-bin\KGEN\tools\mojo\mojo.exe'
if (-not (Test-Path $mojo)) { throw "build the compiler first: .\bazelw.cmd build //KGEN/tools/mojo:mojo" }

# The metadata database: honour an existing setting, else derive from Bazel.
if (-not $env:MODULAR_MOJO_MAX_WINKB_PATH) {
    $candidate = 'F:\bzs\external\+http_archive+winkb\windows_api.db'
    if (-not (Test-Path $candidate)) {
        $base = (& (Join-Path $repo 'bazelw.cmd') info output_base 2>$null | Select-Object -Last 1).Trim()
        $candidate = Join-Path $base 'external\+http_archive+winkb\windows_api.db'
    }
    $env:MODULAR_MOJO_MAX_WINKB_PATH = $candidate
}
Write-Host "metadata: $env:MODULAR_MOJO_MAX_WINKB_PATH"

# Locate cl.exe for the oracle, the way the release launchers do.
function Find-VsDevCmd {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $p = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
        if ($p) { $c = Join-Path $p 'Common7\Tools\VsDevCmd.bat'; if (Test-Path $c) { return $c } }
    }
    return $null
}

$results = @()
function Record($name, $verdict, $note) {
    $script:results += [pscustomobject]@{ Spike = $name; Verdict = $verdict; Note = $note }
    $mark = if ($verdict -eq 'PASS') { 'PASS' } else { $verdict }
    Write-Host ("  {0,-28} {1}  {2}" -f $name, $mark, $note)
}

# ---- the oracle DLL -------------------------------------------------------
Write-Host "== building the cl.exe oracle =="
$oracleDll = Join-Path $repo 'spikes\com\oracle_stream.dll'
$vsdev = Find-VsDevCmd
if ($vsdev) {
    $src = Join-Path $repo 'spikes\com\oracle_stream.c'
    $log = cmd /c "call `"$vsdev`" -no_logo -arch=x64 -host_arch=x64 >nul 2>nul && cl /nologo /LD `"$src`" /Fe:`"$oracleDll`" /Fo:`"$env:TEMP\oracle_stream.obj`" 2>&1"
    if ((Test-Path $oracleDll)) { Write-Host "  oracle_stream.dll built by cl.exe" }
    else { Write-Host "  cl.exe failed:`n$log"; }
} else {
    Write-Host "  no VS C++ toolchain found; s09 will be recorded as SKIP"
}

# ---- must-pass ------------------------------------------------------------
Write-Host "== must-pass =="
$passSpikes = Get-ChildItem (Join-Path $repo 'spikes\com') -Filter 's??_*.mojo' | Sort-Object Name
foreach ($f in $passSpikes) {
    if ($f.Name -eq 's09_cl_oracle.mojo' -and -not (Test-Path $oracleDll)) {
        Record $f.Name 'SKIP' 'no cl.exe on this machine'
        continue
    }
    $out = cmd /c "`"$mojo`" run -I mojo/stdlib spikes/com/$($f.Name) 2>&1" | Out-String
    $code = $LASTEXITCODE
    $tag = ($f.BaseName.Substring(0,3)).ToUpper()
    if ($code -eq 0 -and $out -match "$tag PASS") {
        Record $f.Name 'PASS' ''
    } else {
        [string]$first = (($out -split "`n") | Where-Object { $_ -match 'error|Error|FAIL' } | Select-Object -First 1)
        $first = ($first -replace '\s+', ' ').Trim()
        if ($first.Length -gt 70) { $first = $first.Substring(0, 70) }
        Record $f.Name 'FAIL' $first
    }
}

# ---- must-fail: the interesting half --------------------------------------
Write-Host "== must-fail (each must REFUSE to compile) =="
$failSpikes = Get-ChildItem (Join-Path $repo 'spikes\com') -Filter 'f??_*.mojo' | Sort-Object Name
foreach ($f in $failSpikes) {
    $out = cmd /c "`"$mojo`" run -I mojo/stdlib spikes/com/$($f.Name) 2>&1" | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0 -and $out -match 'error') {
        Record $f.Name 'PASS' 'refused, as designed'
    } elseif ($code -eq 0) {
        Record $f.Name 'FAIL' 'COMPILED -- the check it exists to prove is not firing'
    } else {
        Record $f.Name 'FAIL' 'failed without a diagnostic'
    }
}

# ---- summary --------------------------------------------------------------
$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
$skipped = @($results | Where-Object Verdict -eq 'SKIP').Count
Write-Host ""
Write-Host ("{0} checks: {1} passed, {2} failed, {3} skipped" -f $results.Count, (@($results | Where-Object Verdict -eq 'PASS').Count), $bad, $skipped)
if ($bad -gt 0) { exit 1 }
exit 0
