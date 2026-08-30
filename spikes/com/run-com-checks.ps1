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
# A compiler hang must be a failed check, not a wedged suite. A nested class
# once spun the parser forever -- millions of identical diagnostics and no
# termination -- and the run simply never finished, which reads exactly like a
# slow machine until someone looks. Every compile is capped.
function Invoke-Mojo {
    param([string]$CommandLine, [int]$TimeoutSec = 180)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/c $CommandLine 2>&1"
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        return [pscustomobject]@{
            Output = "TIMED OUT after $TimeoutSec s -- the compiler did not terminate"
            Code   = 124
        }
    }
    return [pscustomobject]@{ Output = $stdout.Result; Code = $proc.ExitCode }
}

$passSpikes = Get-ChildItem (Join-Path $repo 'spikes\com') -Filter 's??_*.mojo' | Sort-Object Name
foreach ($f in $passSpikes) {
    if ($f.Name -eq 's09_cl_oracle.mojo' -and -not (Test-Path $oracleDll)) {
        Record $f.Name 'SKIP' 'no cl.exe on this machine'
        continue
    }
    $r = Invoke-Mojo "`"$mojo`" run -I mojo/stdlib spikes/com/$($f.Name)"
    $out = $r.Output
    $code = $r.Code
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
    $r = Invoke-Mojo "`"$mojo`" run -I mojo/stdlib spikes/com/$($f.Name)"
    $out = $r.Output
    $code = $r.Code
    if ($code -ne 0 -and $out -match 'error') {
        Record $f.Name 'PASS' 'refused, as designed'
    } elseif ($code -eq 124) {
        Record $f.Name 'FAIL' 'the compiler hung -- a refusal must terminate'
    } elseif ($code -eq 0) {
        Record $f.Name 'FAIL' 'COMPILED -- the check it exists to prove is not firing'
    } else {
        Record $f.Name 'FAIL' 'failed without a diagnostic'
    }
}

# ---- CRLF sources ---------------------------------------------------------
# The class desugar captures a class body verbatim, so a file saved with
# Windows line endings puts CR characters inside the generated struct. No
# committed file can prove this stays working -- git normalises line endings
# on checkout -- so the check converts a spike and compiles the copy.
Write-Host "== CRLF source =="
$crlfSrc = Join-Path $repo 'spikes\com\s12_class_keyword.mojo'
$crlfTmp = Join-Path $env:TEMP 'com_crlf_check.mojo'
[System.IO.File]::WriteAllText(
    $crlfTmp,
    ((Get-Content $crlfSrc -Raw) -replace "`r`n", "`n" -replace "`n", "`r`n"))
$out = cmd /c "`"$mojo`" run -I `"$repo\mojo\stdlib`" `"$crlfTmp`" 2>&1"
if ($LASTEXITCODE -eq 0 -and $out -match 'S12 PASS') {
    Record 'crlf-source' 'PASS' 'a CRLF class body compiles'
} else {
    [string]$first = (($out -split "`n") | Where-Object { $_ -match 'error' } | Select-Object -First 1)
    Record 'crlf-source' 'FAIL' $first
}
Remove-Item $crlfTmp -ErrorAction SilentlyContinue

# ---- summary --------------------------------------------------------------
# ---- where a diagnostic points ---------------------------------------------
# A `class` body is copied into a generated buffer and parsed there, so a
# mistake inside one used to be reported against `<class Target>:14:20` -- a
# line in a buffer nobody has seen, in a file that does not exist. Sprint 2.3
# made the generated buffer agree with the original instead of translating
# afterwards. What is checked is not that the file fails to compile, which it
# must, but exactly where the compiler says the problem is.
Write-Host "== diagnostic locations =="
$diagSpikes = Get-ChildItem (Join-Path $repo 'spikes\com') -Filter 'd??_*.mojo' |
    Sort-Object Name
foreach ($f in $diagSpikes) {
    $r = Invoke-Mojo "`"$mojo`" run -I mojo/stdlib spikes/com/$($f.Name)"
    # The file names the line and column it expects, in its own header.
    $want = [regex]::Match((Get-Content $f.FullName -Raw),
        'mistake below is on line (\d+), column (\d+)')
    if (-not $want.Success) {
        Record $f.Name 'FAIL' 'the spike does not say where its mistake is'
        continue
    }
    $line, $col = $want.Groups[1].Value, $want.Groups[2].Value
    $expect = [regex]::Escape($f.Name) + ":${line}:${col}: error:"
    if ($r.Output -match $expect) {
        Record $f.Name 'PASS' "reported at its own line ${line}, column ${col}"
    } elseif ($r.Output -match '<class ') {
        $got = [regex]::Match($r.Output, '<class [^>]*>:\d+:\d+').Value
        Record $f.Name 'FAIL' "reported against the generated buffer: $got"
    } else {
        $first = (($r.Output -split "`n") | Where-Object { $_ -match 'error:' } |
            Select-Object -First 1)
        Record $f.Name 'FAIL' "wanted ${line}:${col}, got: $($first -replace '\s+', ' ')"
    }
}

$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
$skipped = @($results | Where-Object Verdict -eq 'SKIP').Count
Write-Host ""
Write-Host ("{0} checks: {1} passed, {2} failed, {3} skipped" -f $results.Count, (@($results | Where-Object Verdict -eq 'PASS').Count), $bad, $skipped)
if ($bad -gt 0) { exit 1 }
exit 0
