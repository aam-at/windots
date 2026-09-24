@echo off
setlocal
set "YAZI_CWD_FILE=%TEMP%\yazi-cwd-%RANDOM%-%RANDOM%.txt"
yazi --cwd-file="%YAZI_CWD_FILE%" %*
set "YAZI_EXIT=%ERRORLEVEL%"
if exist "%YAZI_CWD_FILE%" (
    for /f "usebackq delims=" %%D in ("%YAZI_CWD_FILE%") do (
        del /q "%YAZI_CWD_FILE%" >nul 2>&1
        endlocal
        cd /d "%%D"
        exit /b %YAZI_EXIT%
    )
)
del /q "%YAZI_CWD_FILE%" >nul 2>&1
endlocal & exit /b %YAZI_EXIT%
