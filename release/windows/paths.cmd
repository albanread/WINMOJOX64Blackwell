@echo off
rem Point this installation at itself.
rem
rem Every path in modular.cfg is absolute -- the compiler is handed a driver, a
rem linker, an import path and a crash handler by name -- and packaging wrote
rem them for whatever directory the release was built into. Unpack the zip
rem somewhere else and the compiler goes looking for a directory that exists
rem only on the machine that packaged it. The failure is not obvious either:
rem `mojo run` reports "unable to locate module 'std'", which reads like a
rem broken installation rather than a moved one.
rem
rem So the file is rewritten from its template whenever this copy has moved.
rem The stamp beside it records the root it was last written for; when that
rem matches, this exits in a few milliseconds and every launcher can afford to
rem call it every time. Making relocation the launcher's job rather than an
rem installer's is what lets the zip be the whole product: unpack it anywhere,
rem including onto a memory stick with a different drive letter each time, and
rem the first command run fixes the paths.

setlocal enabledelayedexpansion

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "TEMPLATE=%ROOT%\modular.cfg.in"
set "CONFIG=%ROOT%\modular.cfg"
set "STAMP=%ROOT%\modular.cfg.root"

rem Nothing to do without a template: a tree built by hand rather than
rem packaged has no modular.cfg to rewrite and needs none.
if not exist "%TEMPLATE%" exit /b 0

if exist "%STAMP%" if exist "%CONFIG%" (
    set "RECORDED="
    set /p RECORDED=<"%STAMP%"
    rem Case-insensitively, because Windows paths are, and because a shortcut
    rem that spells the drive letter in lower case would otherwise rewrite the
    rem file on every single command.
    if /I "!RECORDED!"=="%ROOT%" exit /b 0
)

rem PowerShell for the rewrite rather than batch string substitution: a path
rem can contain characters -- ! and % among them -- that batch expansion eats,
rem and this runs once per relocation rather than once per command.
rem
rem The root travels in the environment rather than on the command line for
rem the same reason: a directory with a space, a quote or an ampersand in it
rem survives being inherited by a child process and does not survive being
rem quoted through cmd into PowerShell's parser.
set "WINMOJO_RELOCATE_ROOT=%ROOT%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$root = $env:WINMOJO_RELOCATE_ROOT;" ^
  "$text = [System.IO.File]::ReadAllText($root + '\modular.cfg.in');" ^
  "$text = $text.Replace('@RELEASE_ROOT@', $root);" ^
  "$utf8 = New-Object System.Text.UTF8Encoding $false;" ^
  "[System.IO.File]::WriteAllText($root + '\modular.cfg', $text, $utf8);" ^
  "[System.IO.File]::WriteAllText($root + '\modular.cfg.root', $root, $utf8);"

if errorlevel 1 (
    echo warning: could not rewrite modular.cfg for this location. 1>&2
    echo          The toolchain will look for files where it was packaged. 1>&2
)
exit /b 0
