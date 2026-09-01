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
    [switch]$Check,
    # Debug is the default because that is the build the debugger work in
    # sprint 0.0 exists to serve, and because -O2 inlines the frames a person
    # wants to stand in, and because debugging belongs at -O0. -Optimized is
    # what the frame-budget runs use; both draw identically, which was not
    # true until docs/addresses-and-optimization.md got written.
    [switch]$Optimized
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

# The icon, compiled to a .res and handed to the linker. An icon in the
# executable is the only kind Explorer, the taskbar and Alt+Tab all read --
# LoadImage at run time can dress a window but cannot put a picture on a
# file. rc.exe comes with the Windows SDK, found the same way mt.exe is
# found below; without it the build carries on and the binary simply has no
# icon, which is a cosmetic loss rather than a reason to fail.
$res = Join-Path (Split-Path $Out) 'griddle.res'
$iconArg = ''
$rcKits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$rc = @(Get-ChildItem (Join-Path $rcKits '*\x64\rc.exe') `
        -ErrorAction SilentlyContinue | Sort-Object FullName)
if ($rc.Count -gt 0) {
    # rc.exe resolves the ICON's own path relative to the .rc file, so it
    # is run from the directory holding both.
    & $rc[-1].FullName /nologo /fo $res (Join-Path $repo 'ide\griddle.rc') 2>&1 | Out-Null
    if (Test-Path $res) {
        $iconArg = "-Xlinker `"$((Resolve-Path $res).Path)`" "
    }
}
if (-not $iconArg) { Write-Host '  (no rc.exe found; building without an icon)' }

$opt = if ($Optimized) { '' } else { '--no-optimization ' }
Write-Host "building $Out$(if ($Optimized) { ' (optimized)' })"
cmd /c "`"$mojo`" build $opt-I mojo/stdlib -I . $iconArg-o `"$Out`" ide\griddle.mojo 2>&1"
if (-not (Test-Path $Out)) { throw "griddle did not link" }

foreach ($dll in @(
    'bazel-bin\KGEN\KGENCompilerRTShared.dll',
    'bazel-bin\AsyncRT\AsyncRTRuntimeGlobals.dll',
    'bazel-bin\Support\MSupportGlobals.dll')) {
    if (Test-Path $dll) {
        Copy-Item $dll (Split-Path $Out) -Force -ErrorAction SilentlyContinue
    }
}

# ---- the manifest --------------------------------------------------------
# Griddle needs to be DPI-aware from its first instruction, and a manifest is
# where a process says so. mojo has no way to hand a .res to the linker, so it
# goes in afterwards with mt.exe, the tool that exists for exactly this.
#
# If mt.exe is not on the machine, the manifest is written beside the binary
# as griddle.exe.manifest instead. Windows reads an external manifest when the
# image has no embedded one, so the fallback is real rather than decorative --
# it just has to travel with the executable. And if neither lands, main calls
# SetProcessDpiAwarenessContext itself. Three ways, because a blurry editor is
# a silent failure and this is the cheap end of finding out.
$manifest = Join-Path $repo 'ide\griddle.manifest'
if (Test-Path $manifest) {
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $mt = @(Get-ChildItem (Join-Path $kits '*\x64\mt.exe') `
            -ErrorAction SilentlyContinue | Sort-Object FullName)
    $embedded = $false
    if ($mt.Count -gt 0) {
        $log = & $mt[-1].FullName -nologo -manifest $manifest `
               "-outputresource:$((Resolve-Path $Out).Path);#1" 2>&1
        # mt.exe reports success by saying nothing and returning 0.
        if ($LASTEXITCODE -eq 0) {
            $embedded = $true
            Write-Host "  manifest embedded (DPI-aware, PerMonitorV2)"
        } else {
            Write-Host "  mt.exe declined: $log"
        }
    }
    if (-not $embedded) {
        Copy-Item $manifest "$Out.manifest" -Force
        Write-Host "  manifest written beside the binary as $(Split-Path -Leaf $Out).manifest"
    } elseif (Test-Path "$Out.manifest") {
        # An external manifest is ignored once one is embedded, and a stale
        # file that no longer matches is worse than no file.
        Remove-Item "$Out.manifest" -Force
    }
}
# ---- the stack -----------------------------------------------------------
# An -O0 Mojo frame is measured in tens of kilobytes -- the window
# procedure's alone came to 67KB -- and the default 1MB reserve was measured
# overflowing under run-script, where script, verb, pump and dispatch frames
# stack a dozen deep. The linker standing in for link.exe ignores -Xlinker,
# so the reserve is set where it actually lives: the PE optional header.
# After mt.exe, which rewrites the file.
$img = [System.IO.File]::ReadAllBytes((Resolve-Path $Out).Path)
$pe = [BitConverter]::ToInt32($img, 0x3C)
if ([BitConverter]::ToUInt16($img, $pe + 24) -eq 0x20B) {
    [BitConverter]::GetBytes([UInt64]8388608).CopyTo($img, $pe + 24 + 72)
    # And the subsystem: an editor is a GUI program, and a console-subsystem
    # editor drags a console window into every launch from a shortcut or the
    # installer. Redirected output still works -- a pipe handle is inherited
    # regardless of subsystem, which is how the check suites keep reading
    # what the agent says -- only an unredirected console launch loses its
    # prints, and those runs are what pipes were invented for.
    [BitConverter]::GetBytes([UInt16]2).CopyTo($img, $pe + 24 + 68)
    [System.IO.File]::WriteAllBytes((Resolve-Path $Out).Path, $img)
    Write-Host "  stack reserve set to 8MB, subsystem set to GUI"
}

Write-Host "staged the runtime beside it; $Out runs on its own"

if ($Check) { & (Join-Path $PSScriptRoot 'check-ide.ps1') -Exe $Out }
