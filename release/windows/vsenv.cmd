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
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
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

call "%MOJO_VSDEVCMD%" -no_logo -arch=x64 -host_arch=x64 >nul
set "MOJO_VSDEVCMD="
exit /b 0
