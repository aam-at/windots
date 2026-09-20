@echo off
setlocal
set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude-work"
claude --dangerously-skip-permissions %*
exit /b %ERRORLEVEL%
