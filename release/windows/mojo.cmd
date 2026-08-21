@echo off
setlocal
set "MOJO_RELEASE_ROOT=%~dp0"
if "%MOJO_RELEASE_ROOT:~-1%"=="\" set "MOJO_RELEASE_ROOT=%MOJO_RELEASE_ROOT:~0,-1%"
set "MODULAR_HOME=%MOJO_RELEASE_ROOT%"
set "PATH=%MOJO_RELEASE_ROOT%\bin;%MOJO_RELEASE_ROOT%\lib;%PATH%"

rem lld-link needs the MSVC/UCRT import-library paths.  Use the x64 toolchain
rem installed on this machine without making the release depend on Bazel.
if not defined VSCMD_VER if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" call "%ProgramFiles%\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" -no_logo -arch=x64 -host_arch=x64 >nul

"%MOJO_RELEASE_ROOT%\bin\mojo.exe" %*
exit /b %ERRORLEVEL%
