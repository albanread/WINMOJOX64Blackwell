@echo off
rem "cuda" is the generic NVIDIA selector: it resolves to whatever card is
rem installed, so this launcher works on any supported GPU rather than the one
rem the release happened to be packaged on. Pass an explicit
rem --target-accelerator to cross-compile for a different card.
call "%~dp0mojo.cmd" run --target-accelerator cuda %*
exit /b %ERRORLEVEL%
