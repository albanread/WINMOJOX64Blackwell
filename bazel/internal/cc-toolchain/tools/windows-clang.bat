@echo off
setlocal EnableExtensions
REM Mirrors multi-platform-clang.sh, which Windows cannot exec. Bazel runs
REM actions from the execution root, so this repo-relative path resolves the
REM same way $PWD/external/... does in the shell version.
if exist "external\+http_archive+clang-windows-x86_64\bin\clang.exe" (
  "external\+http_archive+clang-windows-x86_64\bin\clang.exe" %*
) else (
  "external\+http_archive+clang-windows-arm64\bin\clang.exe" %*
)
set RC=%ERRORLEVEL%
if not "%RC%"=="0" exit /b %RC%
REM parse_headers expects this marker, and only when the compile succeeded.
if defined PARSE_HEADER type nul > "%PARSE_HEADER%"
exit /b 0
