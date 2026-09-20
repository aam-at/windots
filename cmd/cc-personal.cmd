@echo off
setlocal
set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude-personal"
claude --dangerously-skip-permissions %*
exit /b %ERRORLEVEL%
