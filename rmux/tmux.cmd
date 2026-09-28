@echo off
rem `tmux` for Windows programs inside rmux panes (rmux.conf puts this
rem folder first on PATH there), such as tmuxp; the extensionless `tmux`
rem beside it is the one sh jobs use. rmux answers -V as "rmux <version>",
rem which tmux clients can't parse.
if "%~1"=="-V" (
    echo tmux 3.4
    exit /b 0
)
rmux %*
