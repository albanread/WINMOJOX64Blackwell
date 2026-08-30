# check-debugger.ps1 -- the debugger answers, or this fails.
#
# Sprint 0.0's standing check. It builds the fixture the way the IDE's Debug
# action will (--no-optimization --debug-level full, never optimized), then
# asks the two questions the whole toolchain exists to answer: does a
# breakpoint bind, and do variables come back with names and values -- once
# through the CLI and once over DAP, because the IDE uses the second.
#
# A missing-variables regression is packaging breakage, not a soft failure:
# every layer here has silently swallowed debug info at least once. The
# compiler emitted CodeView our own DWARF parser cannot read; the linker
# dropped every debug section for want of one flag; and lldb-dap could not
# be built at all. Each looked exactly like "the debugger is broken".
#
#   .\tools\check-debugger.ps1                 # against bazel-bin
#   .\tools\check-debugger.ps1 -Root <release> # against a release layout
[CmdletBinding()]
param(
    # A release directory containing bin\ and lib\. Default: this build tree.
    [string]$Root = ""
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$results = @()

function Record($name, $verdict, $detail) {
    $script:results += [pscustomobject]@{
        Name = $name; Verdict = $verdict; Detail = $detail
    }
    $pad = $name.PadRight(28)
    Write-Host "  $pad $verdict  $detail"
}

# ---- locate the pieces -----------------------------------------------------
if ($Root) {
    $mojo     = Join-Path $Root 'bin\mojo.exe'
    $lldb     = Join-Path $Root 'bin\mojo-lldb.exe'
    $dap      = Join-Path $Root 'bin\lldb-dap.exe'
    $plugin   = Join-Path $Root 'lib\MojoLLDB.dll'
    $stdlib   = Join-Path $Root 'lib'
    $dllDirs  = @((Join-Path $Root 'bin'), (Join-Path $Root 'lib'))
} else {
    $bb       = Join-Path $repo 'bazel-bin'
    $llvmLldb = Join-Path $bb 'external\+llvm_configure+llvm-project\lldb'
    $mojo     = Join-Path $bb 'KGEN\tools\mojo\mojo.exe'
    $lldb     = Join-Path $llvmLldb 'lldb.exe'
    $dap      = Join-Path $llvmLldb 'lldb-dap.exe'
    $plugin   = Join-Path $bb 'KGEN\MojoLLDB.dll'
    $stdlib   = Join-Path $repo 'mojo\stdlib'
    $dllDirs  = @(
        (Join-Path $bb 'KGEN'), (Join-Path $bb 'AsyncRT'),
        (Join-Path $bb 'Support'), (Join-Path $bb 'nvptx\runtime'), $llvmLldb
    )
}

# mojo shells out to `link.exe`, which on this platform means whichever one
# PATH happens to hold -- MSVC's, or under an MSYS shell coreutils' /usr/bin/
# link, which is not a linker at all. Stage our own lld under that name so
# the check never depends on what else is installed.
$linkDir = Join-Path $env:TEMP 'griddle-linkbin'
New-Item -ItemType Directory -Force -Path $linkDir | Out-Null
$lldSource = if ($Root) {
    Join-Path $Root 'bin\lld-link.exe'
} else {
    Join-Path $repo 'bazel-bin\external\+llvm_configure+llvm-project\lld\lld.exe'
}
if (Test-Path $lldSource) {
    Copy-Item $lldSource (Join-Path $linkDir 'link.exe') -Force
    $dllDirs = @($linkDir) + $dllDirs
}

Write-Host "== debugger check =="
Write-Host "  compiler: $mojo"
foreach ($p in @($mojo, $lldb, $plugin)) {
    if (-not (Test-Path $p)) { throw "missing required artifact: $p" }
}
$env:PATH = ($dllDirs -join ';') + ';' + $env:PATH

# ---- the fixture -----------------------------------------------------------
# Five lines with a call, a local, and a loop: the smallest program in which
# "a variable has a value" is a meaningful question. Shared with the Mac
# port's spike so results compare directly.
$work = Join-Path $env:TEMP 'griddle-dbgcheck'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$src = Join-Path $work 'dbgfix.mojo'
@'
def add(a: Int, b: Int) -> Int:
    var sum = a + b
    return sum


def main():
    var total = 0
    for i in range(5):
        total = add(total, i)
    print("total:", total)
'@ | Set-Content $src -Encoding ascii
$exe = Join-Path $work 'dbgfix.exe'
Remove-Item $exe -ErrorAction SilentlyContinue

# ---- 1. the compiler keeps debug info --------------------------------------
$null = cmd /c "`"$mojo`" build --debug-level full --no-optimization -I `"$stdlib`" -o `"$exe`" `"$src`" 2>&1"
if (-not (Test-Path $exe)) {
    Record 'build-debug-fixture' 'FAIL' 'the fixture did not link'
} else {
    Record 'build-debug-fixture' 'PASS' ''
    $objdump = Join-Path $repo 'bazel-out\..\..' | Out-Null
    $od = (Get-ChildItem -Path 'F:\bzs\external\+http_archive+clang-windows-x86_64\bin\llvm-objdump.exe' -EA SilentlyContinue)
    if ($od) {
        $sections = & $od.FullName -h $exe 2>$null | Select-String '\.debug_info|\.debug_line'
        if ($sections.Count -ge 2) {
            Record 'dwarf-in-image' 'PASS' 'debug_info + debug_line present'
        } else {
            Record 'dwarf-in-image' 'FAIL' 'the image carries no DWARF -- check /debug:dwarf and CodeView=0'
        }
    } else {
        Record 'dwarf-in-image' 'SKIP' 'llvm-objdump not found'
    }
}

# ---- 2. the CLI binds a breakpoint and reads locals ------------------------
if (Test-Path $exe) {
    $script = Join-Path $work 'cli.txt'
    @"
plugin load $plugin
breakpoint set --file dbgfix.mojo --line 3
run
frame variable
quit
"@ | Set-Content $script -Encoding ascii
    $out = cmd /c "`"$lldb`" -b -s `"$script`" `"$exe`" 2>&1"
    $text = ($out | Out-String)
    if ($text -notmatch 'Breakpoint 1: where') {
        Record 'cli-breakpoint' 'FAIL' 'breakpoint never bound'
    } else {
        Record 'cli-breakpoint' 'PASS' ''
        $named = @('a', 'b', 'sum') | Where-Object { $text -match "\)\s$_\s=" }
        if ($named.Count -eq 3) {
            Record 'cli-frame-variable' 'PASS' 'a, b, sum all have values'
        } else {
            Record 'cli-frame-variable' 'FAIL' "only $($named.Count) of 3 locals came back"
        }
    }
}

# ---- 3. the DAP wire the IDE uses ------------------------------------------
if (-not (Test-Path $dap)) {
    Record 'dap-probe' 'FAIL' 'lldb-dap.exe is not in this layout'
} elseif (Test-Path $exe) {
    $probe = Join-Path $repo 'tools\dap-probe.py'
    $out = cmd /c "python `"$probe`" `"$dap`" `"$plugin`" `"$exe`" `"$src`" 3 2>&1"
    $text = ($out | Out-String)
    if ($text -match 'DAP PROBE PASS') {
        $n = if ($text -match 'PASS -- .*?(\d+) variable') { $matches[1] } else { '?' }
        Record 'dap-probe' 'PASS' "$n variables over the wire"
    } else {
        [string]$why = (($text -split "`n") |
            Where-Object { $_ -match 'FAIL|TIMEOUT|error' } | Select-Object -First 1)
        Record 'dap-probe' 'FAIL' $why.Trim()
    }
}

# ---- summary ---------------------------------------------------------------
$bad = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host ("{0} checks: {1} passed, {2} failed, {3} skipped" -f `
    $results.Count,
    (@($results | Where-Object Verdict -eq 'PASS').Count),
    $bad,
    (@($results | Where-Object Verdict -eq 'SKIP').Count))
if ($bad -gt 0) { exit 1 }
exit 0
