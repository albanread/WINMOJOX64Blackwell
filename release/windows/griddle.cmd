@echo off
rem Start the IDE against this installation.
rem
rem Griddle finds its own toolchain -- ide/toolchain.mojo walks up from the
rem executable looking for one -- so most of what this does is make the
rem environment match what that lookup will find, and hand it the two things
rem it cannot work out: the Win32 metadata database, and the directories the
rem runtime DLLs live in.

setlocal
set "WINMOJO_ROOT=%~dp0"
if "%WINMOJO_ROOT:~-1%"=="\" set "WINMOJO_ROOT=%WINMOJO_ROOT:~0,-1%"

rem First, in case this copy has been moved since it was packaged.
call "%WINMOJO_ROOT%\paths.cmd"

set "MODULAR_HOME=%WINMOJO_ROOT%"
set "MODULAR_MOJO_MAX_WINKB_PATH=%WINMOJO_ROOT%\lib\windows_api.db"

rem bin for the compiler and the debugger, lib for the runtime DLLs a built
rem program loads. Griddle stages its own copy of the linker at startup and
rem does not need one here.
set "PATH=%WINMOJO_ROOT%\bin;%WINMOJO_ROOT%\lib;%PATH%"

rem The import path, so a program built from the IDE resolves `std` without
rem anybody passing -I. An installed toolchain ships std.mojoc rather than the
rem stdlib sources, and the compiler reads it out of import_path in
rem modular.cfg -- which paths.cmd has just pointed here.

rem The MSVC import libraries, for linking. mojo run does not need them and
rem mojo build does; vsenv says so itself when it cannot find them.
call "%WINMOJO_ROOT%\vsenv.cmd"

start "" "%WINMOJO_ROOT%\bin\griddle.exe" %*
exit /b 0
