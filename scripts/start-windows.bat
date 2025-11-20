@echo off
cd /d "%~dp0"

if not exist ".configed_flag" (
    echo First run, starting configuration wizard...
    powershell -ExecutionPolicy Bypass -File "setup-config.ps1"
    if errorlevel 1 (
        echo Configuration failed. Please check the error.
        pause
        exit /b 1
    )
)

java -Dfile.encoding=utf-8 -jar "sonic-agent-windows-x86_64.jar"
if errorlevel 1 (
    echo Java startup failed. Please ensure Java is installed and in PATH.
    pause
)