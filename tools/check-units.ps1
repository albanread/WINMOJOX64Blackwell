# The unit tests -- the ones that are plain Mojo and need no window.
#
# ide\*_test.mojo had been accumulating since sprint 1.1 with nothing to run
# them: four files, all green, none of them executed by any check script. A
# test that nothing runs is a comment with a compiler cost.
#
# These need no HWND, no Direct2D and no language server, which is the point:
# when the machine cannot present a frame (docs\occlusion.md) these still say
# whether the rope, the JSON writer, the LSP framing and the lexer are right.
#
#     .\tools\check-units.ps1
#     .\tools\check-units.ps1 -Only syntax

param(
    [string]$Only = ''
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$mojo = 'bazel-bin\KGEN\tools\mojo\mojo.exe'
if (-not (Test-Path $mojo)) {
    throw "build the compiler first: .\bazelw.cmd build //KGEN/tools/mojo:mojo"
}
if (-not $env:MODULAR_MOJO_MAX_WINKB_PATH) {
    $db = 'F:\bzs\external\+http_archive+winkb\windows_api.db'
    if (Test-Path $db) { $env:MODULAR_MOJO_MAX_WINKB_PATH = $db }
}

# mojo shells out to `link.exe`; stage our own lld under that name so the run
# does not depend on whichever linker happens to be on PATH.
$linkDir = Join-Path $env:TEMP 'griddle-linkbin'
New-Item -ItemType Directory -Force -Path $linkDir | Out-Null
$lld = 'bazel-bin\external\+llvm_configure+llvm-project\lld\lld.exe'
if (Test-Path $lld) {
    Copy-Item $lld (Join-Path $linkDir 'link.exe') -Force -ErrorAction SilentlyContinue
}
$env:PATH = "$linkDir;" + $env:PATH

Write-Host "== unit tests =="

$passed = 0
$failed = 0
$files = @(Get-ChildItem (Join-Path $repo 'ide') -Filter '*_test.mojo' | Sort-Object Name)
if ($Only) {
    $files = @($files | Where-Object { $_.BaseName -replace '_test$', '' -eq $Only })
    if ($files.Count -eq 0) { throw "no test file matches -Only $Only" }
}

foreach ($f in $files) {
    $name = $f.BaseName -replace '_test$', ''
    # -I ide as well as -I . because these import their subject by bare name
    # (`from syntax import ...`), the way a test sitting beside it would.
    $out = cmd /c "`"$mojo`" run -I mojo/stdlib -I ide -I . `"$($f.FullName)`" 2>&1"
    $ok = $LASTEXITCODE -eq 0
    if ($ok) {
        # The count is the test's own OK lines, so the summary reports work
        # done rather than files touched.
        $cases = @($out | Select-String -Pattern '^\s+OK\s').Count
        Write-Host ("  {0,-10} PASS  {1} cases" -f $name, $cases)
        $passed++
    } else {
        $why = @($out | Select-String -Pattern 'FAIL|error:')
        $first = if ($why.Count) { $why[0].ToString().Trim() } else { 'exited non-zero' }
        Write-Host ("  {0,-10} FAIL  {1}" -f $name, $first) -ForegroundColor Red
        foreach ($line in @($why | Select-Object -First 8)) {
            Write-Host ("             {0}" -f $line.ToString().Trim())
        }
        $failed++
    }
}

Write-Host ""
Write-Host ("{0} test files: {1} passed, {2} failed" -f $files.Count, $passed, $failed)
if ($failed) { exit 1 }
