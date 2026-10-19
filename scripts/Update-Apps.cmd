@echo off
setlocal
rem Use Windows PowerShell so this updater does not lock Scoop's pwsh package.
rem Open from Explorer after closing PowerShell 7 sessions.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Apps.ps1" %*
set "updateExitCode=%ERRORLEVEL%"
pause
exit /b %updateExitCode%
