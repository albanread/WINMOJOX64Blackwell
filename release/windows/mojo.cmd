@echo off
setlocal
set "MOJO_RELEASE_ROOT=%~dp0"
if "%MOJO_RELEASE_ROOT:~-1%"=="\" set "MOJO_RELEASE_ROOT=%MOJO_RELEASE_ROOT:~0,-1%"
set "MODULAR_HOME=%MOJO_RELEASE_ROOT%"
set "PATH=%MOJO_RELEASE_ROOT%\bin;%MOJO_RELEASE_ROOT%\lib;%PATH%"

rem lld-link needs the MSVC/UCRT import-library paths. Resolved without
rem assuming an edition or install root; see vsenv.cmd.
call "%MOJO_RELEASE_ROOT%\vsenv.cmd"

"%MOJO_RELEASE_ROOT%\bin\mojo.exe" %*
exit /b %ERRORLEVEL%
