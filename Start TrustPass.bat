@echo off
setlocal
cd /d "%~dp0"

where python >nul 2>&1
if errorlevel 1 (
  echo Python was not found. Install Python 3.10 or newer, then run this file again.
  pause
  exit /b 1
)

netstat -ano | findstr /R /C:":8000 .*LISTENING" >nul
if errorlevel 1 (
  start "TrustPass local server" /D "%~dp0" cmd /k python backend\server.py
  timeout /t 2 /nobreak >nul
)

start "" "http://127.0.0.1:8000"
endlocal
