#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodeRain"
APP_PATH="$HOME/Applications/${APP_NAME}.app"

pkill -x "$APP_NAME" 2>/dev/null || true
osascript -e "tell application \"System Events\" to delete (every login item whose path is \"${APP_PATH}\")" 2>/dev/null || true
rm -rf "$APP_PATH"

echo "✅ Removed $APP_PATH, deregistered from Login Items."
