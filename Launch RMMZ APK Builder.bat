@echo off
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0RMMZ-APK-Builder.ps1"
if errorlevel 1 (
    echo.
    echo ============================================================
    echo  The app closed with an error - details should be above.
    echo ============================================================
    pause
)
