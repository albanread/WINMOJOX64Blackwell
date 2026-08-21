@echo off
set "MOJO_RELEASE_ROOT=%~dp0"
if "%MOJO_RELEASE_ROOT:~-1%"=="\" set "MOJO_RELEASE_ROOT=%MOJO_RELEASE_ROOT:~0,-1%"
set "MODULAR_HOME=%MOJO_RELEASE_ROOT%"
set "PATH=%MOJO_RELEASE_ROOT%\bin;%MOJO_RELEASE_ROOT%\lib;%PATH%"
if not defined VSCMD_VER if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" call "%ProgramFiles%\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" -no_logo -arch=x64 -host_arch=x64 >nul
echo Mojo x64 / NVIDIA Blackwell environment ready.
echo GPU target: sm_120a
cmd /k
