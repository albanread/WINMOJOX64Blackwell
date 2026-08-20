@echo off
setlocal enabledelayedexpansion

if "%BAZEL_REAL%"=="" (
  echo error: bazel should be run through the .\bazelw.cmd script at the root of the repo 1>&2
  exit /b 1
)

set "SCRIPT_ROOT=%~dp0"
set "REPO_ROOT=%SCRIPT_ROOT%.."
set "BAZELRC_ROOT=%REPO_ROOT%\build"

REM Match against the whole command line rather than iterating tokens: cmd's
REM `for` treats "=" as a delimiter, which splits --config=build-mojo in two.
set "IS_BUILD_TEST_OR_RUN=false"
set "HAS_MOJO_CONFIG=false"

if "%~1"=="build" set "IS_BUILD_TEST_OR_RUN=true"
if "%~1"=="test" set "IS_BUILD_TEST_OR_RUN=true"
if "%~1"=="run" set "IS_BUILD_TEST_OR_RUN=true"

echo %*| findstr /C:"--config=build-mojo" >nul 2>&1
if not errorlevel 1 set "HAS_MOJO_CONFIG=true"
echo %*| findstr /C:"--config=prebuilt-mojo" >nul 2>&1
if not errorlevel 1 set "HAS_MOJO_CONFIG=true"

if exist "%REPO_ROOT%\local.bazelrc" (
  findstr /R /C:"config=prebuilt-mojo" /C:"config=build-mojo" "%REPO_ROOT%\local.bazelrc" >nul 2>&1
  if not errorlevel 1 set "HAS_MOJO_CONFIG=true"
)

if "%IS_BUILD_TEST_OR_RUN%"=="true" if "%HAS_MOJO_CONFIG%"=="false" (
  echo Please add `--config=build-mojo` to your command line.
  echo.
  echo On Windows, `--config=prebuilt-mojo` cannot work: it downloads a prebuilt
  echo Mojo toolchain, and no Windows build of that toolchain is published.
  echo Building the compiler from source is the only option on this platform.
  echo.
  echo You can add `build --config=build-mojo` to a `local.bazelrc` file to have
  echo it apply to all Bazel calls.
  exit /b 1
)

REM Some actions, such as the builtin module map generator, are shell scripts.
REM Bazel needs BAZEL_SH to find a bash on Windows; without it those actions
REM fail with "The system cannot find the file specified".
if "%BAZEL_SH%"=="" (
  for %%p in (
    "%ProgramFiles%\Git\usr\bin\bash.exe"
    "%ProgramFiles%\Git\bin\bash.exe"
    "%ProgramFiles(x86)%\Git\usr\bin\bash.exe"
    "%LOCALAPPDATA%\Programs\Git\usr\bin\bash.exe"
  ) do (
    if exist %%p if "!BAZEL_SH!"=="" set "BAZEL_SH=%%~p"
  )
)

if not exist "%BAZELRC_ROOT%\logs" mkdir "%BAZELRC_ROOT%\logs"

if not exist "%BAZELRC_ROOT%\local-resources.bazelrc" (
  type nul > "%BAZELRC_ROOT%\local-resources.bazelrc"
)

set "WHO=%USERNAME%"
if not "%GITHUB_ACTOR%"=="" set "WHO=%GITHUB_ACTOR%"

REM This file is imported after bazel/internal/common.bazelrc, so anything
REM written here overrides it. That ordering is the point: Bazel has no
REM 'sandboxed' strategy on Windows and naming one is a hard error rather than a
REM fallback, so the strategy lines have to be restated without it. A
REM build:windows section cannot do that, because an auto-applied
REM --config=windows expands before those unconditional lines and is then
REM overridden by them.
> "%BAZELRC_ROOT%\wrapper.bazelrc" (
  echo # Generated from tools/bazel.bat, do not edit.
  echo build --build_metadata=USER=%WHO%
  if "%GITHUB_REPOSITORY%"=="" echo build --config=disk-cache
  echo build --build_metadata=TAG_HOST_OS=windows
  echo build --build_metadata=TAG_TARGET_OS=windows
  echo build --spawn_strategy=remote,worker,standalone
  echo build --strategy=TestRunner=remote,worker,standalone
  echo build --experimental_output_paths=off
  echo # rules_shell's toolchain repo detects bash through BAZEL_SH in the
  echo # *repository* environment, which the client env does not reach. Without
  echo # this every sh_binary — including bazel_tools' collect_coverage, an
  echo # implicit dep of every test — fails analysis with "No suitable shell
  echo # toolchain found", taking the whole test graph down with it.
  echo build "--repo_env=BAZEL_SH=%BAZEL_SH%"
  echo # PE/COFF has no rpath: a DLL is found through the executable's directory
  echo # and the search path. Bazel's runtime_library_search_directories feature
  echo # emits -Wl,-rpath,$ORIGIN/... regardless, which lld-link reads as a
  echo # filename. The feature is neither overridable nor separately disableable
  echo # in the toolchain, so it is switched off by name here.
  echo build --features=-runtime_library_search_directories
  echo # --host_features as well: every failing link was a [for tool] target,
  echo # and --features applies only to the target configuration.
  echo build --host_features=-runtime_library_search_directories
  echo import %%workspace%%/build/local-resources.bazelrc
)

if exist "%BAZELRC_ROOT%\logs\execution.log" (
  move /y "%BAZELRC_ROOT%\logs\execution.log" "%BAZELRC_ROOT%\logs\execution-previous.log" >nul
)

"%BAZEL_REAL%" %*
exit /b %ERRORLEVEL%
