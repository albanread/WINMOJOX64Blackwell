@echo off
set "MOJO_RELEASE_ROOT=%~dp0"
if "%MOJO_RELEASE_ROOT:~-1%"=="\" set "MOJO_RELEASE_ROOT=%MOJO_RELEASE_ROOT:~0,-1%"

rem Before anything reads modular.cfg: this copy may have been
rem unpacked somewhere other than where it was packaged, and every
rem path in that file is absolute.
call "%MOJO_RELEASE_ROOT%\paths.cmd"
set "MODULAR_HOME=%MOJO_RELEASE_ROOT%"
set "PATH=%MOJO_RELEASE_ROOT%\bin;%MOJO_RELEASE_ROOT%\lib;%PATH%"

rem No setlocal here on purpose: the environment has to survive into the
rem interactive shell started below.
call "%MOJO_RELEASE_ROOT%\vsenv.cmd"

echo Mojo x64 / NVIDIA environment ready.
for /f "usebackq tokens=*" %%g in (`nvidia-smi --query-gpu^=gpu_name --format^=csv,noheader 2^>nul`) do echo GPU detected: %%g
echo GPU target: selected automatically; pass --target-accelerator to override.
cmd /k
