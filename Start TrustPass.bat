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

powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8000/api/bootstrap; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
  start "TrustPass local server" /D "%~dp0" cmd /k %PYTHON% backend\server.py
  for /L %%i in (1,1,30) do (
    timeout /t 1 /nobreak >nul
    powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8000/api/bootstrap; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
    if not errorlevel 1 goto :open_browser
  )
  echo TrustPass did not respond on port 8000. Check the server window for details.
  pause
  exit /b 1
)

:open_browser
start "" "http://127.0.0.1:8000"
endlocal
