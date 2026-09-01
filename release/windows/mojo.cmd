@echo off
setlocal
set "MOJO_RELEASE_ROOT=%~dp0"
if "%MOJO_RELEASE_ROOT:~-1%"=="\" set "MOJO_RELEASE_ROOT=%MOJO_RELEASE_ROOT:~0,-1%"

rem Before anything reads modular.cfg: this copy may have been
rem unpacked somewhere other than where it was packaged, and every
rem path in that file is absolute.
call "%MOJO_RELEASE_ROOT%\paths.cmd"
set "MODULAR_HOME=%MOJO_RELEASE_ROOT%"
set "PATH=%MOJO_RELEASE_ROOT%\bin;%MOJO_RELEASE_ROOT%\lib;%PATH%"

rem lld-link needs the MSVC/UCRT import-library paths. Resolved without
rem assuming an edition or install root; see vsenv.cmd.
call "%MOJO_RELEASE_ROOT%\vsenv.cmd"

"%MOJO_RELEASE_ROOT%\bin\mojo.exe" %*
exit /b %ERRORLEVEL%
