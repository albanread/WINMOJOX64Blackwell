# build-ide.ps1 -- build Griddle and stage what it needs to run.
#
# The staging is the point. A freshly linked griddle.exe imports
# KGENCompilerRTShared.dll, which lives in bazel-bin and is not on anyone's
# PATH: run the executable directly and it dies before its window survives,
# which looks exactly like a program that opens and instantly closes. The
# runtime belongs beside the binary, the way the release ships it.
[CmdletBinding()]
param(
    [string]$Out = 'build\griddle.exe',
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$mojo = 'bazel-bin\KGEN\tools\mojo\mojo.exe'
if (-not (Test-Path $mojo)) { throw "build the compiler first: .\bazelw.cmd build //KGEN/tools/mojo:mojo" }

# mojo shells out to `link.exe`; stage our own lld under that name so the
# build does not depend on whichever linker happens to be on PATH.
$linkDir = Join-Path $env:TEMP 'griddle-linkbin'
New-Item -ItemType Directory -Force -Path $linkDir | Out-Null
Copy-Item 'bazel-bin\external\+llvm_configure+llvm-project\lld\lld.exe' (Join-Path $linkDir 'link.exe') -Force
$env:PATH = "$linkDir;" + $env:PATH
$env:MODULAR_MOJO_MAX_WINKB_PATH = (Resolve-Path 'F:\bzs\external\+http_archive+winkb\windows_api.db' -EA SilentlyContinue)

New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
Write-Host "building $Out"
cmd /c "`"$mojo`" build --no-optimization -I mojo/stdlib -I . -o `"$Out`" ide\griddle.mojo 2>&1"
if (-not (Test-Path $Out)) { throw "griddle did not link" }

foreach ($dll in @(
    'bazel-bin\KGEN\KGENCompilerRTShared.dll',
    'bazel-bin\AsyncRT\AsyncRTRuntimeGlobals.dll',
    'bazel-bin\Support\MSupportGlobals.dll')) {
    if (Test-Path $dll) { Copy-Item $dll (Split-Path $Out) -Force }
}
Write-Host "staged the runtime beside it; $Out runs on its own"

if ($Check) { & (Join-Path $PSScriptRoot 'check-ide.ps1') -Exe $Out }
