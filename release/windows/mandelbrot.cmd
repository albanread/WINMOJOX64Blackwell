@echo off
set "PATH=%~dp0bin;%~dp0lib;%~dp0examples;%PATH%"
"%~dp0examples\nvidia_mandelbrot.exe"
exit /b %ERRORLEVEL%
