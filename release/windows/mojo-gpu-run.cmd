@echo off
call "%~dp0mojo.cmd" run --target-accelerator sm_120a %*
exit /b %ERRORLEVEL%
