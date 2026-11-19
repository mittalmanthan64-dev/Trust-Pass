#!/bin/bash

cd "$(dirname "$0")" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3.10 or newer is required. Install Python, then double-click this file again."
  read -r -p "Press Return to close this window..."
  exit 1
fi

<<<<<<< HEAD
if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Python 3.10 or newer is required. Your current python3 is too old."
  read -r -p "Press Return to close this window..."
  exit 1
fi

APP_URL="http://127.0.0.1:8000"

if curl --silent --fail --max-time 2 "$APP_URL/api/bootstrap" >/dev/null; then
=======
APP_URL="http://127.0.0.1:8000"

if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
>>>>>>> f6723c15a5492e0c02469040f2080544b79f6a0c
  open "$APP_URL"
  echo "TrustPass is already running at $APP_URL"
  read -r -p "Press Return to close this window..."
  exit 0
fi

<<<<<<< HEAD
if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port 8000 is in use by another app. Close it or change PORT, then try again."
  read -r -p "Press Return to close this window..."
  exit 1
fi

=======
>>>>>>> f6723c15a5492e0c02469040f2080544b79f6a0c
python3 backend/server.py &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT INT TERM

READY=0
for _ in {1..30}; do
  if curl --silent --fail "$APP_URL/api/bootstrap" >/dev/null; then
    READY=1
    break
  fi
  sleep 0.5
done

if [ "$READY" -ne 1 ]; then
  echo "TrustPass did not start. Check that port 8000 is available."
  wait "$SERVER_PID"
  exit 1
fi

open "$APP_URL"
echo "TrustPass is running at $APP_URL. Keep this Terminal window open while using the app."
wait "$SERVER_PID"
