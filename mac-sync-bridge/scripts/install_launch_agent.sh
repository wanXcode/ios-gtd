#!/usr/bin/env bash
set -euo pipefail

LABEL="com.iosgtd.syncbridge"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$PROJECT_ROOT/launchd/$LABEL.plist"
CONFIG_PATH="${1:-$HOME/Library/Application Support/GTD/mac-sync-bridge/config.json}"
LOG_DIR="${2:-$HOME/Library/Logs/GTD/mac-sync-bridge}"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PATH="$AGENT_DIR/$LABEL.plist"

mkdir -p "$AGENT_DIR"
mkdir -p "$(dirname "$CONFIG_PATH")"
mkdir -p "$LOG_DIR"

if [[ ! -f "$CONFIG_PATH" ]]; then
  EXAMPLE_PATH="$PROJECT_ROOT/config/config.example.json"
  cp "$EXAMPLE_PATH" "$CONFIG_PATH"
  echo "Created config from example: $CONFIG_PATH"
  echo "Edit bridgeID/backendBaseURL/apiToken/list identifiers before loading LaunchAgent."
fi

python3 - <<PY
from pathlib import Path

template = Path(r'''$TEMPLATE_PATH''').read_text()
rendered = (template
    .replace('__CONFIG_PATH__', r'''$CONFIG_PATH''')
    .replace('__WORKDIR__', r'''$PROJECT_ROOT''')
    .replace('__LOG_DIR__', r'''$LOG_DIR''')
    .replace('__HOME__', r'''$HOME'''))
Path(r'''$AGENT_PATH''').write_text(rendered)
PY

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PATH"
launchctl enable "gui/$(id -u)/$LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed LaunchAgent: $AGENT_PATH"
echo "Config path: $CONFIG_PATH"
echo "Logs: $LOG_DIR"
echo "Inspect: launchctl print gui/$(id -u)/$LABEL"
