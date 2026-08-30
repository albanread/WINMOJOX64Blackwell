[CmdletBinding()]
param(
    [string]$Destination = 'C:\projects\mojo_release',
    [string]$OutputBase
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
    'lib\nvptxrt.lib' = 'bazel-bin\nvptx\runtime\nvptxrt.lib'
    'lib\std.mojoc' = 'bazel-bin\mojo\stdlib\std\std.mojoc'
    'lib\max.mojoc' = 'bazel-bin\max\mojo\max\max.mojoc'
    'lib\windows_api.db' = (Join-Path $OutputBase 'external\+http_archive+winkb\windows_api.db')
    'examples\nvidia_mandelbrot.mojo' = 'examples\win32\nvidia_mandelbrot.mojo'
    'examples\nvidia_mandelbrot.exe' = 'bazel-bin\examples\win32\nvidia_mandelbrot.exe'
    'examples\AsyncRTRuntimeGlobals.dll' = 'bazel-bin\AsyncRT\AsyncRTRuntimeGlobals.dll'
    'examples\MSupportGlobals.dll' = 'bazel-bin\Support\MSupportGlobals.dll'
    'examples\KGENCompilerRTShared.dll' = 'bazel-bin\KGEN\KGENCompilerRTShared.dll'
    'examples\nvptxrt.dll' = 'bazel-bin\nvptx\runtime\nvptxrt.dll'
    'LICENSE' = 'LICENSE'
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

$licenseDirectory = Join-Path $repository 'Licenses'
if (Test-Path -LiteralPath $licenseDirectory -PathType Container) {
    Copy-Item -LiteralPath $licenseDirectory -Destination $destinationPath -Recurse -Force
}

$config = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'modular.cfg.in') -Raw).Replace('@RELEASE_ROOT@', $destinationPath)
[System.IO.File]::WriteAllText((Join-Path $destinationPath 'modular.cfg'), $config, [System.Text.UTF8Encoding]::new($false))

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
