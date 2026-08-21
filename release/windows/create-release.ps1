[CmdletBinding()]
param(
    [string]$Destination = 'C:\projects\mojo_release'
)

$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
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
    'lib\windows_api.db' = 'C:\b\w\external\+http_archive+winkb\windows_api.db'
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
        $relativePath = [System.IO.Path]::GetRelativePath($destinationPath, $_.FullName)
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relativePath"
    }
[System.IO.File]::WriteAllLines($manifestPath, $hashLines, [System.Text.UTF8Encoding]::new($false))

$totalBytes = (Get-ChildItem -LiteralPath $destinationPath -File -Recurse | Measure-Object -Property Length -Sum).Sum
Write-Host ('Release created at {0} ({1:N1} MiB).' -f $destinationPath, ($totalBytes / 1MB))
