# install-test.ps1 -- prove the installer, the way a user's machine would.
#
# Silent install into a directory that is not the staging one, then run the
# installed Griddle with the repo's environment stripped -- no
# MODULAR_MOJO_MAX_WINKB_PATH, no MODULAR_HOME, no repo on PATH -- so
# anything it finds, it found through its own installation. Then uninstall
# and check what remains.
param(
    [Parameter(Mandatory)][string]$Setup,
    [string]$Target = 'F:\winmojo-release\test-install'
)
$ErrorActionPreference = 'Stop'
$fail = 0
function Check($name, $ok, $detail) {
    Write-Host ("  {0} {1}  {2}" -f $name.PadRight(24), $(if ($ok) {'PASS'} else {'FAIL'}), $detail)
    if (-not $ok) { $script:fail++ }
}

Write-Host "== installer check =="
if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }

# ---- 1. silent install ----------------------------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $Setup -ArgumentList '/S', "/D=$Target" -Wait -PassThru
Check 'silent-install' ($p.ExitCode -eq 0) "exit $($p.ExitCode) after $([int]$sw.Elapsed.TotalSeconds)s"

Check 'compiler-present'  (Test-Path "$Target\bin\mojo.exe") 'bin\mojo.exe'
Check 'ide-present'       (Test-Path "$Target\bin\griddle.exe") 'bin\griddle.exe'
Check 'lsp-present'       (Test-Path "$Target\bin\mojo-lsp-server.exe") 'bin\mojo-lsp-server.exe'
Check 'metadata-present'  (Test-Path "$Target\lib\windows_api.db") 'lib\windows_api.db'
Check 'stdlib-present'    (Test-Path "$Target\lib\std.mojoc") 'lib\std.mojoc'
Check 'python-present'    (Test-Path "$Target\python\python.exe") 'python\python.exe'
Check 'guide-present'     (Test-Path "$Target\WinMojoGuide\index.md") 'WinMojoGuide\index.md'
Check 'examples-present'  (Test-Path "$Target\examples\win32\life\main.mojo") 'examples\win32\life'
$cfg = if (Test-Path "$Target\modular.cfg") { Get-Content "$Target\modular.cfg" -Raw } else { '' }
Check 'cfg-relocated'     ($cfg -match [regex]::Escape($Target)) 'modular.cfg names the install dir'
$uninst = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo' -ErrorAction SilentlyContinue
Check 'apps-and-features'  ($null -ne $uninst) "DisplayVersion $($uninst.DisplayVersion)"

# ---- 2. the installed IDE, in a stranger's environment --------------------
$scrub = @('MODULAR_MOJO_MAX_WINKB_PATH', 'MODULAR_HOME', 'GRIDDLE_PYTHON_HOME', 'MOJO_PYTHON', 'MOJO_PYTHON_LIBRARY')
$saved = @{}
foreach ($v in $scrub) { $saved[$v] = [Environment]::GetEnvironmentVariable($v); [Environment]::SetEnvironmentVariable($v, $null) }
$savedPath = $env:PATH
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
try {
    $hello = "$Target\examples\hello.mojo"
    $out = & cmd /c "`"$Target\bin\griddle.exe`" --open `"$hello`" --no-lsp --cmd `"toolchain;;python;;build;;build wait 240000`" 2>&1" | Out-String

    Check 'toolchain-is-local'  ($out -match [regex]::Escape("$Target\bin\mojo.exe")) 'the view names the installed compiler'
    Check 'no-repo-paths'       ($out -notmatch 'E:\\Mojo|bazel-bin|F:/bzs|F:\\bzs') 'nothing points at the checkout'
    Check 'python-is-bundled'   ($out -match [regex]::Escape("$Target\python")) 'python view names the bundled runtime'
    Check 'hello-builds'        ($out -match 'exit 0') 'built and ran from the installed toolchain'
    if ($fail -gt 0) {
        Write-Host '--- transcript tail ---'
        ($out -split "`r?`n" | Select-Object -Last 25) | ForEach-Object { Write-Host "  $_" }
    }
} finally {
    $env:PATH = $savedPath
    foreach ($v in $scrub) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
}

# ---- 3. uninstall ---------------------------------------------------------
# A witness for the per-user data question: the uninstaller asks whether to
# remove %LOCALAPPDATA%\Griddle, and its SILENT answer must be No. An
# unattended uninstall that quietly deletes somebody's settings is a bug
# even when the directory is ours.
$userData = Join-Path $env:LOCALAPPDATA 'Griddle'
$hadUserData = Test-Path $userData
if (-not $hadUserData) {
    New-Item -ItemType Directory -Path $userData -Force | Out-Null
    Set-Content (Join-Path $userData 'settings.json') '{"witness":true}' -Encoding utf8
}

# NSIS silent uninstall copies itself to temp and returns at once; _?= makes
# it run in place and actually wait.
$p = Start-Process -FilePath "$Target\uninstall.exe" -ArgumentList '/S', "_?=$Target" -Wait -PassThru
Check 'silent-uninstall' ($p.ExitCode -eq 0) "exit $($p.ExitCode)"
Check 'keeps-user-data' (Test-Path $userData) 'a silent uninstall does not delete settings'
if (-not $hadUserData) { Remove-Item $userData -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item "$Target\uninstall.exe" -Force -ErrorAction SilentlyContinue
Remove-Item $Target -Force -ErrorAction SilentlyContinue
Check 'tree-removed' (-not (Test-Path "$Target\bin")) 'installation directory gone'
$uninst = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo' -ErrorAction SilentlyContinue
Check 'registry-removed' ($null -eq $uninst) 'uninstall entry gone'

Write-Host ("{0} failures" -f $fail)
exit $(if ($fail -gt 0) { 1 } else { 0 })
