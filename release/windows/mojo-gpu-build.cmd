@echo off
rem See mojo-gpu-run.cmd: "cuda" resolves to the installed card.
call "%~dp0mojo.cmd" build --target-accelerator cuda %*
exit /b %ERRORLEVEL%
