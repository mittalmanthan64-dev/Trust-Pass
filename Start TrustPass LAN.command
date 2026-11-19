#!/bin/bash

cd "$(dirname "$0")" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3.10 or newer is required. Install Python, then run this file again."
  read -r -p "Press Return to close this window..."
  exit 1
fi

if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Python 3.10 or newer is required. Your current python3 is too old."
  read -r -p "Press Return to close this window..."
  exit 1
fi

if ! python3 -c 'import argon2' >/dev/null 2>&1; then
  echo "Installing TrustPass security dependencies (one-time setup)..."
  if ! python3 -m pip install -r requirements.txt; then
    echo "Dependency installation failed. Check your internet connection and try again."
    read -r -p "Press Return to close this window..."
    exit 1
  fi
fi

APP_URL="http://127.0.0.1:8000"
if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port 8000 is already in use. Stop the other TrustPass server first (press Ctrl+C in its Terminal window), then try again."
  read -r -p "Press Return to close this window..."
  exit 1
fi

WIFI_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
TRUSTPASS_HOST=0.0.0.0 python3 backend/server.py &
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
echo "TrustPass is running on this Mac at $APP_URL."
if [ -n "$WIFI_IP" ]; then
  echo "On another device on the same Wi-Fi, open: http://$WIFI_IP:8000"
else
  echo "Find this Mac's Wi-Fi IPv4 address in System Settings > Wi-Fi > Details, then open http://<address>:8000 on the other device."
fi
echo "Allow incoming Python connections only on a trusted private network if macOS asks. Keep this Terminal window open."
wait "$SERVER_PID"
