# Build a QNN model library on Windows ARM64.
#
# qnn-model-lib-generator cannot do this unaided on a stock VS install: it
# hardcodes `cmake -T ClangCL`, and the generated model code uses C compound
# literals - `(Qnn_Tensor_t){...}` - which are a Clang extension and are not
# valid ISO C++ at any standard level, so MSVC cannot build it at all.
#
# This drives the generator far enough to stage sources and objects, then
# configures CMake itself with Ninja + clang-cl.
#
#   .\build_model_lib.ps1 -Cpp <model.cpp> -Bin <model.bin> -Out <dir>

param(
    [Parameter(Mandatory=$true)][string]$Cpp,
    [Parameter(Mandatory=$true)][string]$Bin,
    [Parameter(Mandatory=$true)][string]$Out
)

$ErrorActionPreference = "Stop"

$R = $env:QNN_SDK_ROOT
if (-not $R) { throw "QNN_SDK_ROOT is not set" }

$VSROOT = "C:\Program Files\Microsoft Visual Studio\18\Professional"
$VSC    = "$VSROOT\Common7\IDE\CommonExtensions\Microsoft\CMake"
$vcvars = "$VSROOT\VC\Auxiliary\Build\vcvarsarm64.bat"

# clang is required. WINMOJO's bazel toolchain already downloads one; prefer an
# explicit CLANG_BIN if the caller knows better.
$CLANGBIN = $env:CLANG_BIN
if (-not $CLANGBIN) {
    $found = Get-ChildItem -Path "$env:USERPROFILE\_bazel_$env:USERNAME" -Recurse `
        -Filter "clang-cl.exe" -ErrorAction SilentlyContinue -Force | Select-Object -First 1
    if (-not $found) { throw "no clang-cl.exe found; set CLANG_BIN to a directory containing one" }
    $CLANGBIN = $found.Directory.FullName
}
Write-Host "clang-cl: $CLANGBIN"

New-Item -ItemType Directory -Force $Out | Out-Null
Set-Location $Out

# Stage. This step extracts the .bin's raw tensors into .o files via
# object-generator.exe, then fails at its own cmake call - which is expected.
$gen = "$R\bin\aarch64-windows-msvc\qnn-model-lib-generator"
cmd /c "`"$vcvars`" >nul 2>&1 && python `"$gen`" -c `"$Cpp`" -b `"$Bin`" -t windows-aarch64 -o `"$Out\ignored`" 2>&1" |
    Select-String "Extracted raw|Converted raw" | ForEach-Object { Write-Host "  $_" }

# The generator writes its staging tree to tmp_<pid> in the CURRENT directory,
# not into -o, and leaves it behind.
$T = Get-ChildItem $Out -Filter "tmp_*" -Directory | Select-Object -First 1
if (-not $T) { throw "generator left no staging tree" }

# Its CMakeLists branches on CMAKE_GENERATOR_PLATFORM, which Ninja refuses to
# accept. Key off the directory that actually exists instead.
$cml = Join-Path $T.FullName "CMakeLists.txt"
(Get-Content $cml -Raw).Replace(
    'if(${CMAKE_GENERATOR_PLATFORM} STREQUAL "ARM64")',
    'if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/obj/windows-aarch64")'
) | Set-Content $cml -Encoding utf8

$b = Join-Path $T.FullName "build"
New-Item -ItemType Directory -Force $b | Out-Null

# Note the quoted `set "VAR=value"`. Without the quotes cmd captures the space
# before && into the value, and QNN_SDK_ROOT becomes "...251225 ", which then
# produces an include path of "...251225 \include\QNN" and a file-not-found on
# QnnInterface.h that looks nothing like a quoting bug.
$script = "`"$vcvars`" >nul 2>&1 && set `"QNN_SDK_ROOT=$R`" && " +
          "set `"PATH=$VSC\CMake\bin;$VSC\Ninja;$CLANGBIN;%PATH%`" && " +
          "cd /d `"$b`" && cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release " +
          "-DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl && cmake --build ."
cmd /c $script 2>&1 | Select-Object -Last 6

$dll = Join-Path $b "model-lib-windows.dll"
if (-not (Test-Path $dll)) { throw "build produced no DLL" }
Write-Host "`nbuilt: $dll ($((Get-Item $dll).Length) bytes)"
