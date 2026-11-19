@echo off
setlocal
cd /d "%~dp0"

set "PYTHON=python"
where python >nul 2>&1
if errorlevel 1 (
  where py >nul 2>&1
  if errorlevel 1 (
    echo Python 3.10 or newer was not found. Install Python and try again.
    pause
    exit /b 1
  )
  set "PYTHON=py -3"
)

%PYTHON% -c "import sys; raise SystemExit(sys.version_info < (3, 10))"
if errorlevel 1 (
  echo Python 3.10 or newer is required. Update Python and try again.
  pause
  exit /b 1
)

%PYTHON% -c "import argon2" >nul 2>&1
if errorlevel 1 (
  echo Installing TrustPass security dependencies (one-time setup)...
  %PYTHON% -m pip install -r requirements.txt
  if errorlevel 1 (
    echo Dependency installation failed. Check your internet connection and try again.
    pause
    exit /b 1
  )
)

powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8000/api/bootstrap; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
if not errorlevel 1 (
  echo TrustPass is already running locally. To share it over Wi-Fi, stop that server with Ctrl+C and run this LAN launcher again.
  pause
  exit /b 0
)

netstat -ano | findstr /R /C:":8000 .*LISTENING" >nul
if not errorlevel 1 (
  echo Port 8000 is in use by another app. Close it or change PORT, then try again.
  pause
  exit /b 1
)

echo Starting TrustPass for devices on this private Wi-Fi network.
echo Use ipconfig to find this computer's IPv4 address, then open http://YOUR-IP:8000 on the other device.
echo Allow Python through Windows Firewall only on a trusted private network if prompted.
start "TrustPass LAN server" /D "%~dp0" cmd /k "set TRUSTPASS_HOST=0.0.0.0 && %PYTHON% backend\server.py"
for /L %%i in (1,1,30) do (
  timeout /t 1 /nobreak >nul
  powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8000/api/bootstrap; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
  if not errorlevel 1 goto :open_lan
)
echo TrustPass did not respond on port 8000. Check the server window for details.
pause
exit /b 1

:open_lan
start "" "http://127.0.0.1:8000"
echo In the other device's browser, enter this computer's IPv4 address with :8000.
echo Example: http://192.168.1.10:8000
ipconfig | findstr /C:"IPv4 Address"
echo Keep the TrustPass LAN server window open while using the app.
pause
endlocal
