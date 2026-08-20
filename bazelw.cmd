@echo off
setlocal enabledelayedexpansion

set "VERSION=1.27.0"

if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" ( set "PLATFORM=windows-arm64" ) else (
  if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" ( set "PLATFORM=windows-arm64" ) else ( set "PLATFORM=windows-amd64" )
)

set "SCRIPT_ROOT=%~dp0"
set "EXECUTABLE=%SCRIPT_ROOT%build\bazelisk-%VERSION%-%PLATFORM%.exe"

if not exist "%EXECUTABLE%" (
  echo Installing bazelisk... 1>&2
  if not exist "%SCRIPT_ROOT%build" mkdir "%SCRIPT_ROOT%build"
  curl --fail -L --retry 5 --retry-connrefused --silent --output "%EXECUTABLE%" ^
    "https://github.com/bazelbuild/bazelisk/releases/download/v%VERSION%/bazelisk-%PLATFORM%.exe"
  if errorlevel 1 (
    echo error: failed to download bazelisk 1>&2
    if exist "%EXECUTABLE%" del /q "%EXECUTABLE%"
    exit /b 1
  )
)

rem Bazel's test launcher takes the bash path from BAZEL_SH and puts it through
rem an escape pass that eats backslashes, so a path like
rem C:\Program Files\Git\usr\bin\bash.exe arrives as C:Program FilesGitusrbinbash.exe.
rem That is no longer absolute, so Rlocation treats it as a runfiles key, fails
rem to find it, and every test dies before its first line with
rem "LAUNCHER ERROR: Rlocation failed". The same path spelled with forward
rem slashes survives the escape pass unchanged.
if not defined BAZEL_SH (
  if exist "C:/Program Files/Git/usr/bin/bash.exe" set "BAZEL_SH=C:/Program Files/Git/usr/bin/bash.exe"
)

set "BAZEL=%EXECUTABLE%"
"%EXECUTABLE%" %*
exit /b %ERRORLEVEL%
