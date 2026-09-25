@echo off
setlocal
set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude-work"
set "CLAUDE_CODE_USE_POWERSHELL_TOOL=1"
claude --dangerously-skip-permissions %*
exit /b %ERRORLEVEL%
