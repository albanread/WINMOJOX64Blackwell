@echo off
rem Put the MSVC and UCRT import-library paths into the environment.
rem
rem The release ships its own linker (lld-link) but not Microsoft's import
rem libraries, so `mojo build` still needs a local Visual Studio or Build Tools
rem installation to link against. `mojo run` does not, which is what makes the
rem failure confusing: JIT keeps working while AOT fails with
rem "unable to find suitable c compiler for linking".
rem
rem Nothing here assumes an edition or an install root. The previous version
rem hardcoded VS 2022 Community under %ProgramFiles% and was guarded by
rem `if exist`, so on a machine with Build Tools -- which installs under
rem Program Files (x86) -- it silently did nothing at all.

if defined VSCMD_VER exit /b 0

rem Delayed expansion is required, not stylistic. vswhere.exe lives under
rem Program Files (x86), and %VAR% inside a parenthesised block is substituted
rem while the block is being parsed, so the ")" of "(x86)" would close the
rem block early. !VAR! is substituted at execution time instead.
setlocal enabledelayedexpansion

set "VSDEVCMD="
set "PF64=%ProgramFiles%"
set "PF32=%ProgramFiles(x86)%"
set "VSWHERE=!PF32!\Microsoft Visual Studio\Installer\vswhere.exe"

rem Ask the installer first: it knows every edition and side-by-side version,
rem and -requires filters to installs that actually carry the x64 C++
rem toolchain rather than, say, a C#-only one.
rem
rem Its stderr is discarded. On some installations this probe prints
rem "'vswhere.exe' is not recognized" while still answering correctly, and a
rem red line on every single command is a bad first impression of a release
rem that is working. Nothing is hidden by it: if no toolchain is found by
rem either this or the fallback below, the warning at the end of this file
rem says so in full.
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do (
        if exist "%%i\Common7\Tools\VsDevCmd.bat" set "VSDEVCMD=%%i\Common7\Tools\VsDevCmd.bat"
    )
)

rem Fall back to probing the conventional locations, for installs vswhere does
rem not report or machines where it is absent. %%~r and friends are for
rem variables, expanded at execution time, so paths containing "(x86)" are safe
rem here.
if not defined VSDEVCMD (
    for %%r in ("!PF64!" "!PF32!") do (
        for %%v in (18 2022 2019 2017) do (
            for %%e in (BuildTools Community Professional Enterprise) do (
                if not defined VSDEVCMD if exist "%%~r\Microsoft Visual Studio\%%v\%%e\Common7\Tools\VsDevCmd.bat" set "VSDEVCMD=%%~r\Microsoft Visual Studio\%%v\%%e\Common7\Tools\VsDevCmd.bat"
            )
        )
    )
)

rem Carry the one result out of the setlocal scope. The whole line is parsed
rem before any of it runs, so %VSDEVCMD% still holds the inner value.
endlocal & set "MOJO_VSDEVCMD=%VSDEVCMD%"

if not defined MOJO_VSDEVCMD (
    echo warning: no Visual Studio x64 toolchain was found. 1>&2
    echo          "mojo run" will still work. "mojo build" will fail to link, 1>&2
    echo          because the MSVC and UCRT import libraries cannot be located. 1>&2
    echo          Install the Visual Studio Build Tools with the x64 C++ 1>&2
    echo          workload, or run from a Developer Command Prompt. 1>&2
    exit /b 0
)

rem Both streams discarded, and the outcome checked instead. VsDevCmd.bat
rem runs vswhere itself and on this machine prints "'vswhere.exe' is not
rem recognized" to stderr while going on to set the environment correctly --
rem a red line on every command in a release that is working perfectly. What
rem matters is whether it worked, and VSCMD_VER answers that: the script sets
rem it, so its absence afterwards means the environment was not set up and is
rem worth saying out loud.
call "%MOJO_VSDEVCMD%" -no_logo -arch=x64 -host_arch=x64 >nul 2>nul
set "MOJO_VSDEVCMD="
if not defined VSCMD_VER (
    echo warning: the Visual Studio environment script did not complete. 1>&2
    echo          "mojo build" may fail to link. Run from a Developer 1>&2
    echo          Command Prompt if it does. 1>&2
)
exit /b 0
