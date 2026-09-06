[CmdletBinding()]
param(
    [string]$Destination = 'C:\projects\mojo_release',
    [string]$OutputBase,
    [switch]$NoArchive,
    # Also produce a per-user NSIS installer beside the zip. Needs makensis:
    # either pass -MakeNsis, or unzip the portable NSIS into build\nsis-3.11.
    [switch]$Installer,
    [string]$MakeNsis,
    # zlib instead of solid LZMA in the installer, for a fast test cycle.
    [switch]$QuickInstaller
)

$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path

# Almost every artifact below is reached through the repo-relative bazel-bin
# symlink, which works wherever the output base happens to live. windows_api.db
# is the exception: it comes from an external repository, which sits in the
# output base itself. That path used to be hardcoded to C:\b\w -- one machine's
# --output_base -- so packaging failed anywhere else with a missing-artifact
# error naming a directory the user had never configured.
function Get-BazelOutputBase {
    param([string]$Repository)

    # Prefer the convenience symlink: no Bazel server needed, and the layout
    # <output_base>\execroot\<workspace>\bazel-out is stable.
    $marker = Join-Path $Repository 'bazel-out'
    if (Test-Path -LiteralPath $marker) {
        $target = (Get-Item -LiteralPath $marker -Force).Target
        if ($target) {
            if ($target -is [array]) { $target = $target[0] }
            $probe = [System.IO.Path]::GetFullPath($target)
            for ($i = 0; $i -lt 3; $i++) { $probe = Split-Path -Parent $probe }
            if ($probe -and (Test-Path -LiteralPath (Join-Path $probe 'external'))) {
                return $probe
            }
        }
    }

    # Otherwise ask Bazel directly.
    $bazelw = Join-Path $Repository 'bazelw.cmd'
    if (Test-Path -LiteralPath $bazelw) {
        $reported = & $bazelw info output_base 2>$null | Select-Object -Last 1
        if ($LASTEXITCODE -eq 0 -and $reported) { return $reported.Trim() }
    }

    throw "Could not determine the Bazel output base. Build the tree first, or pass -OutputBase."
}

if (-not $OutputBase) { $OutputBase = Get-BazelOutputBase -Repository $repository }
$OutputBase = $OutputBase.TrimEnd('\', '/')
Write-Host "Bazel output base: $OutputBase"
$destinationPath = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($destinationPath -eq [System.IO.Path]::GetPathRoot($destinationPath)) {
    throw "Refusing to package a release into a drive root: $destinationPath"
}

$artifacts = [ordered]@{
    'bin\mojo.exe' = 'bazel-bin\KGEN\tools\mojo\mojo.exe'
    # The IDE. A release that ships a compiler and no editor is a toolchain;
    # shipping both is the product. Built by tools/build-griddle.ps1, which
    # this script does not run -- packaging copies what is there and says so
    # when it is not, rather than quietly building something different from
    # what was tested.
    'bin\griddle.exe' = 'build\griddle.exe'
    # The language server. Without it the IDE has no diagnostics, no
    # completion, no hover, no go-to-definition and no outline -- an editor
    # with syntax colouring. It was missing until Griddle's own toolchain
    # view, run from a packaged copy, reported it as the one component that
    # was not there.
    'bin\mojo-lsp-server.exe' = 'bazel-bin\KGEN\tools\mojo-lsp-server\mojo-lsp-server.exe'
    'bin\mojo-lldb.exe' = 'bazel-bin\external\+llvm_configure+llvm-project\lldb\lldb.exe'
    'bin\lld.exe' = 'bazel-bin\external\+llvm_configure+llvm-project\lld\lld.exe'
    'bin\lld-link.exe' = 'bazel-bin\external\+llvm_configure+llvm-project\lld\lld.exe'
    'bin\lldb-argdumper.exe' = 'bazel-bin\external\+llvm_configure+llvm-project\lldb\lldb-argdumper.exe'
    # The DAP adapter an IDE talks to. Ships beside the CLI debugger because
    # a release that debugs from a terminal but not from an editor is half a
    # debugger; tools/dap-probe.py checks it against this very layout.
    'bin\lldb-dap.exe' = 'bazel-bin\external\+llvm_configure+llvm-project\lldb\lldb-dap.exe'
    'bin\llvm-symbolizer.exe' = 'bazel-bin\external\+llvm_configure+llvm-project\llvm\llvm-symbolizer.exe'
    'bin\lldb24.0.0git.dll' = 'bazel-bin\external\+llvm_configure+llvm-project\lldb\lldb24.0.0git.dll'
    'bin\modular-crashpad-handler.exe' = 'bazel-bin\external\+http_archive+crashpad\modular-crashpad-handler.exe'
    # The runtime DLLs, beside the executables as well as in lib. Windows
    # searches an executable's own directory before PATH, so bin\griddle.exe
    # launched directly -- pinned to a taskbar, double-clicked, which is how
    # anybody actually starts an editor -- could not load these and exited
    # before it drew anything. Three megabytes to make a direct launch work.
    'bin\KGENCompilerRTShared.dll' = 'bazel-bin\KGEN\KGENCompilerRTShared.dll'
    'bin\AsyncRTRuntimeGlobals.dll' = 'bazel-bin\AsyncRT\AsyncRTRuntimeGlobals.dll'
    'bin\MSupportGlobals.dll' = 'bazel-bin\Support\MSupportGlobals.dll'
    'bin\nvptxrt.dll' = 'bazel-bin\nvptx\runtime\nvptxrt.dll'
    'lib\MojoLLDB.dll' = 'bazel-bin\KGEN\MojoLLDB.dll'
    'lib\MojoLLDB.lib' = 'bazel-bin\KGEN\MojoLLDB.lib'
    'lib\mojo-repl-entry-point.exe' = 'bazel-bin\KGEN\tools\mojo-repl-entry-point\mojo-repl-entry-point.exe'
    'lib\KGENCompilerRTShared.dll' = 'bazel-bin\KGEN\KGENCompilerRTShared.dll'
    'lib\KGENCompilerRTShared.lib' = 'bazel-bin\KGEN\KGENCompilerRTShared.lib'
    'lib\AsyncRTRuntimeGlobals.dll' = 'bazel-bin\AsyncRT\AsyncRTRuntimeGlobals.dll'
    'lib\AsyncRTRuntimeGlobals.lib' = 'bazel-bin\AsyncRT\AsyncRTRuntimeGlobals.lib'
    'lib\MSupportGlobals.dll' = 'bazel-bin\Support\MSupportGlobals.dll'
    'lib\MSupportGlobals.lib' = 'bazel-bin\Support\MSupportGlobals.lib'
    'lib\nvptxrt.dll' = 'bazel-bin\nvptx\runtime\nvptxrt.dll'
    # The IMPORT library, not the static archive Bazel builds under the same
    # name: a program links a few kilobytes of stubs and loads the DLL, so
    # a runtime fix reaches every program already built against it.
    'lib\nvptxrt.lib' = 'bazel-bin\nvptx\runtime\nvptxrt.if.lib'
    'lib\std.mojoc' = 'bazel-bin\mojo\stdlib\std\std.mojoc'
    'lib\max.mojoc' = 'bazel-bin\max\mojo\max\max.mojoc'
    'lib\windows_api.db' = (Join-Path $OutputBase 'external\+http_archive+winkb\windows_api.db')
    'examples\nvidia_mandelbrot.mojo' = 'examples\win32\nvidia_mandelbrot\main.mojo'
    'examples\nvidia_mandelbrot.exe' = 'bazel-bin\examples\win32\nvidia_mandelbrot.exe'
    'examples\AsyncRTRuntimeGlobals.dll' = 'bazel-bin\AsyncRT\AsyncRTRuntimeGlobals.dll'
    'examples\MSupportGlobals.dll' = 'bazel-bin\Support\MSupportGlobals.dll'
    'examples\KGENCompilerRTShared.dll' = 'bazel-bin\KGEN\KGENCompilerRTShared.dll'
    'examples\nvptxrt.dll' = 'bazel-bin\nvptx\runtime\nvptxrt.dll'
    'LICENSE' = 'LICENSE'
}

# The curated Windows examples, which the IDE's Samples menu reads. Every one
# of these builds with the toolchain in this release; three of them
# (the adreno_* trio) target Qualcomm hardware and will build here and refuse
# to run on an NVIDIA machine, which is a fact about the example rather than
# about the release, and the menu says so.
# Each example is a project in a folder of its own -- main.mojo, a README,
# and whatever else it needs -- so this copies the folders whole rather than
# picking out the .mojo files. Build output from a previous run is left
# behind: an example that ships with someone else's .exe in it is not the
# pristine copy it is meant to be.
$exampleRoot = Join-Path $repository 'examples\win32'
$exampleProjects = Get-ChildItem -LiteralPath $exampleRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'main.mojo') } |
    Sort-Object Name
foreach ($project in $exampleProjects) {
    foreach ($file in (Get-ChildItem -LiteralPath $project.FullName -File -Recurse)) {
        if ($file.Extension -in @('.exe', '.lib', '.pdb', '.obj')) { continue }
        # Editor state from whoever last opened the example is not part of it.
        if ($file.Name -eq '.griddle-session.json') { continue }
        $relative = $file.FullName.Substring($exampleRoot.Length).TrimStart('\\')
        $artifacts['examples\win32\' + $relative] = 'examples\win32\' + $relative
    }
}

$resolvedArtifacts = [ordered]@{}
foreach ($entry in $artifacts.GetEnumerator()) {
    $source = $entry.Value
    if (-not [System.IO.Path]::IsPathRooted($source)) {
        $source = Join-Path $repository $source
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required release artifact is missing: $source"
    }
    $resolvedArtifacts[$entry.Key] = (Resolve-Path -LiteralPath $source).Path
}

$templateFiles = @(
    'README.md',
    # The template and the relocator. Both have to be inside the package: the
    # config is rewritten from the template by whichever launcher runs first
    # after the package is moved, so a copy that carries neither is a copy
    # that can only work in the directory it was packaged into.
    'modular.cfg.in',
    'paths.cmd',
    'install.ps1',
    'griddle.cmd',
    'mojo.cmd',
    'vsenv.cmd',
    'mojo-shell.cmd',
    'mojo-gpu-run.cmd',
    'mojo-gpu-build.cmd',
    'mandelbrot.cmd',
    'examples\hello.mojo'
)
foreach ($relativePath in $templateFiles) {
    $source = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required release template is missing: $source"
    }
}

New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
foreach ($directory in @('bin', 'lib', 'examples', 'cache', 'crashdb')) {
    New-Item -ItemType Directory -Path (Join-Path $destinationPath $directory) -Force | Out-Null
}

foreach ($entry in $resolvedArtifacts.GetEnumerator()) {
    $target = Join-Path $destinationPath $entry.Key
    $targetParent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    Copy-Item -LiteralPath $entry.Value -Destination $target -Force
}

foreach ($relativePath in $templateFiles) {
    $source = Join-Path $PSScriptRoot $relativePath
    $target = Join-Path $destinationPath $relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
}

# ---- the Python runtime -------------------------------------------------
# ide/python_env.mojo probes `<toolchain>\python` for the interpreter that
# creates environments and provides MOJO_PYTHON_LIBRARY. The standalone
# CPython Bazel fetched for this very build is relocatable by construction,
# so the newest one it holds ships as that directory. Without it, Python in
# an installed copy depends on what the user's machine happens to have --
# and what it happens to have is usually the Microsoft Store stub.
$pythonSource = $null
$externalRoot = Join-Path $OutputBase 'external'
$pythonDirs = Get-ChildItem -LiteralPath $externalRoot -Directory -Filter 'rules_python++python+python_3_*_x86_64-pc-windows-msvc' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'python.exe') } |
    Sort-Object @{Expression = { [int]($_.Name -replace '.*python_3_(\d+)_.*', '$1') }} -Descending
if ($pythonDirs) { $pythonSource = $pythonDirs[0].FullName }
if ($pythonSource) {
    Write-Host "Bundling Python from $pythonSource"
    $pythonTarget = Join-Path $destinationPath 'python'
    if (Test-Path -LiteralPath $pythonTarget) { Remove-Item -LiteralPath $pythonTarget -Recurse -Force }
    Copy-Item -LiteralPath $pythonSource -Destination $pythonTarget -Recurse -Force
    # Bazel leaves its own bookkeeping in the fetched tree; none of it is
    # Python's and some of it (BUILD files, MODULE.bazel) confuses a reader
    # into thinking the directory is a workspace.
    foreach ($junk in @('BUILD.bazel', 'MODULE.bazel', 'WORKSPACE', 'REPO.bazel')) {
        $junkPath = Join-Path $pythonTarget $junk
        if (Test-Path -LiteralPath $junkPath) { Remove-Item -LiteralPath $junkPath -Force }
    }
} else {
    Write-Warning 'No standalone CPython found in the Bazel external tree; the release will have no bundled Python.'
}

# ---- the guide ------------------------------------------------------------
# WinMojoGuide is the user documentation. A release without it hands the
# user a toolchain and no book.
$guideSource = Join-Path $repository 'WinMojoGuide'
if (Test-Path -LiteralPath $guideSource -PathType Container) {
    # Removed first, and that is not tidiness. Copy-Item -Recurse at a
    # destination that ALREADY EXISTS copies the source folder INTO it, so a
    # second packaging run produced WinMojoGuide\WinMojoGuide and every later
    # run refreshed only the nested copy -- leaving the outer one, the one
    # readers open and the one check-install.ps1 tests for, frozen at
    # whatever the first run wrote. It would have gone stale silently and no
    # check would have said so. The Python block above got this right; this
    # line did not, which is the whole argument for the two looking alike.
    $guideTarget = Join-Path $destinationPath 'WinMojoGuide'
    if (Test-Path -LiteralPath $guideTarget) {
        Remove-Item -LiteralPath $guideTarget -Recurse -Force
    }
    Copy-Item -LiteralPath $guideSource -Destination $guideTarget -Recurse -Force
}

$licenseDirectory = Join-Path $repository 'Licenses'
if (Test-Path -LiteralPath $licenseDirectory -PathType Container) {
    Copy-Item -LiteralPath $licenseDirectory -Destination $destinationPath -Recurse -Force
}

$config = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'modular.cfg.in') -Raw).Replace('@RELEASE_ROOT@', $destinationPath)
[System.IO.File]::WriteAllText((Join-Path $destinationPath 'modular.cfg'), $config, [System.Text.UTF8Encoding]::new($false))

# The root this config was written for. paths.cmd compares it against where
# the package actually is and rewrites modular.cfg when they differ, so a
# release used where it was built never pays for the check.
[System.IO.File]::WriteAllText((Join-Path $destinationPath 'modular.cfg.root'), $destinationPath, [System.Text.UTF8Encoding]::new($false))

$revision = (git -C $repository rev-parse --short HEAD).Trim()
[System.IO.File]::WriteAllText((Join-Path $destinationPath 'BUILD-REVISION.txt'), "$revision`r`n", [System.Text.UTF8Encoding]::new($false))

$manifestPath = Join-Path $destinationPath 'SHA256SUMS.txt'
$hashLines = Get-ChildItem -LiteralPath $destinationPath -File -Recurse |
    Where-Object { $_.FullName -ne $manifestPath } |
    Sort-Object FullName |
    ForEach-Object {
        # Not [System.IO.Path]::GetRelativePath: that is .NET Core only, so it
        # throws MethodNotFound on Windows PowerShell 5.1, which is what ships
        # with Windows. Every file here is under $destinationPath, which is
        # already absolute and has no trailing separator, so trimming the
        # prefix is exact.
        $relativePath = $_.FullName.Substring($destinationPath.Length).TrimStart('\')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relativePath"
    }
[System.IO.File]::WriteAllLines($manifestPath, $hashLines, [System.Text.UTF8Encoding]::new($false))

$totalBytes = (Get-ChildItem -LiteralPath $destinationPath -File -Recurse | Measure-Object -Property Length -Sum).Sum
Write-Host ('Release created at {0} ({1:N1} MiB).' -f $destinationPath, ($totalBytes / 1MB))

if (-not $NoArchive) {
    # The zip is the deliverable. Everything above assembles a directory; this
    # is what somebody downloads, and it is deliberately a plain archive
    # rather than a self-extracting executable -- an unsigned .exe from the
    # internet is a thing people are right to be suspicious of, and the
    # package relocates itself wherever it lands, so there is nothing for an
    # installer to do that Explorer's "Extract All" does not.
    $archivePath = $destinationPath + '-' + $revision + '.zip'
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
    Write-Host 'Compressing...'
    # -CompressionLevel Optimal on 670 MiB takes a while; Fastest is within a
    # few per cent on binaries that are mostly already-compressed sections.
    Compress-Archive -Path (Join-Path $destinationPath '*') -DestinationPath $archivePath -CompressionLevel Fastest
    $zipBytes = (Get-Item -LiteralPath $archivePath).Length
    Write-Host ('Archive: {0} ({1:N1} MiB).' -f $archivePath, ($zipBytes / 1MB))
    $zipHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText($archivePath + '.sha256', "$zipHash  $(Split-Path -Leaf $archivePath)`r`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "sha256: $zipHash"
}

if ($Installer) {
    $makensis = $MakeNsis
    if (-not $makensis) {
        $candidates = @(
            (Join-Path $repository 'build\nsis-3.11\makensis.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe')
        )
        $makensis = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $makensis) {
        Write-Warning 'makensis.exe not found; skipping the installer. Pass -MakeNsis or unzip the portable NSIS into build\nsis-3.11.'
    } else {
        $setupPath = $destinationPath + '-setup-' + $revision + '.exe'
        $nsiArgs = @('/V2', "/DRELEASE_DIR=$destinationPath", "/DREVISION=$revision", "/DOUTFILE=$setupPath")
        if ($QuickInstaller) { $nsiArgs += '/DQUICK' }
        $nsiArgs += (Join-Path $PSScriptRoot 'installer.nsi')
        & $makensis @nsiArgs
        if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }
        $setupBytes = (Get-Item -LiteralPath $setupPath).Length
        Write-Host ('Installer: {0} ({1:N1} MiB).' -f $setupPath, ($setupBytes / 1MB))
        $setupHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($setupPath + '.sha256', "$setupHash  $(Split-Path -Leaf $setupPath)`r`n", [System.Text.UTF8Encoding]::new($false))
        Write-Host "sha256: $setupHash"
    }
}
