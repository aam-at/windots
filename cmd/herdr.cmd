@echo off
rem herdr panes use %SHELL% (the shared herdr config leaves default_shell
rem unset). Point it at pwsh for herdr only; its server inherits it. Found
rem before Scoop's herdr.exe because ~/.local/bin leads the user PATH, so this covers
rem cmd, pwsh and the Run dialog alike.
setlocal
for /f "delims=" %%p in ('where pwsh.exe 2^>nul') do if not defined HERDR_PWSH set "HERDR_PWSH=%%p"
if defined HERDR_PWSH set "SHELL=%HERDR_PWSH%"
herdr.exe %*
exit /b %ERRORLEVEL%
