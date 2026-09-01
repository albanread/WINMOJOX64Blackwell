# check-packaged.ps1 -- build every example the way an INSTALLED copy does.
#
# The check that was missing, and whose absence shipped a release in which not
# one example compiled. Every other sweep in this tree builds with
# "-I mojo\stdlib", which is the standard library AS SOURCE. A release ships
# it as std.mojoc, a PACKAGE, and the two do not resolve the same names: a
# symbol that some stdlib module merely uses is visible in that module's
# namespace when the compiler reads source, and is gone once the package is
# compiled. "from std.memory import Span" was the example -- Span is really
# exported from std.collections, std/memory/alloc.mojo happens to use it, and
# five examples plus a spike imported it from the wrong place and built
# perfectly for months.
#
# So this builds against the package, with nothing but what an installed copy
# has. Run it before packaging; a green dev sweep does not mean anything here.
#
#   .\tools\check-packaged.ps1                     # against the built release stage
#   .\tools\check-packaged.ps1 -Root C:\WinMojo    # against an installed copy
[CmdletBinding()]
param(
    [string]$Root = 'F:\winmojo-release\stage'
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path (Join-Path $Root 'bin\mojo.exe'))) {
    throw "not a release tree (no bin\mojo.exe): $Root"
}
if (-not (Test-Path (Join-Path $Root 'lib\std.mojoc'))) {
    throw "no packaged stdlib in $Root -- this check is meaningless without it"
}

# What the launchers set, and what the IDE sets for itself at startup. Without
# MODULAR_HOME the compiler cannot find modular.cfg, and without modular.cfg it
# cannot find the packaged stdlib -- which reads as "unable to locate module
# 'std'" and looks like a broken install rather than a missing variable.
$env:MODULAR_HOME = $Root
$env:PATH = "$Root\bin;$Root\lib;$env:PATH"
$mojo = Join-Path $Root 'bin\mojo.exe'

$exampleRoot = Join-Path $Root 'examples\win32'
$projects = Get-ChildItem -LiteralPath $exampleRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'main.mojo') } | Sort-Object Name
if (-not $projects) { throw "no example projects under $exampleRoot" }

Write-Host "== packaged build check =="
Write-Host "  root: $Root"
$pass = 0; $fail = 0; $failed = @()
foreach ($p in $projects) {
    $exe = Join-Path $p.FullName 'main.exe'
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Push-Location $p.FullName
    # A project is a folder and the thing compiled is always its main.mojo.
    $out = & cmd /c "`"$mojo`" build --no-optimization -I . -o `"$exe`" main.mojo 2>&1" | Out-String
    Pop-Location
    if (Test-Path $exe) {
        $pass++
        Write-Host ("  {0} PASS" -f $p.Name.PadRight(22))
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
    } else {
        $fail++; $failed += $p.Name
        $why = ($out -split "`r?`n" | Where-Object { $_ -match 'error' } | Select-Object -First 1)
        Write-Host ("  {0} FAIL  {1}" -f $p.Name.PadRight(22), $why)
    }
}
Write-Host ""
Write-Host ("{0} example projects: {1} built, {2} failed" -f $projects.Count, $pass, $fail)
if ($fail -gt 0) {
    Write-Host "failed: $($failed -join ', ')"
    exit 1
}
exit 0
