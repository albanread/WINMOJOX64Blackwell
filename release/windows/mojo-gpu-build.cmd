@echo off
call "%~dp0mojo.cmd" build --target-accelerator sm_120a %*
exit /b %ERRORLEVEL%
