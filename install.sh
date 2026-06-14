#!/usr/bin/env bash
# Install the Claude Session Widget (and, by default, the usage poller) as
# per-user launchd agents that start at login.
#
#   ./install.sh              widget + poller (exact, matches claude.ai)
#   ./install.sh --widget-only   widget only (transcript estimate, no network)
#
# Everything is per-user — nothing is installed system-wide, nothing needs sudo.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UIDN="$(id -u)"
LA="$HOME/Library/LaunchAgents"
APP_DEST="$HOME/Applications/SessionWidget.app"
POLLER_DEST="$HOME/.claude/session_usage_poll.py"
WIDGET_LABEL="com.claude-session-widget.app"
POLLER_LABEL="com.claude-session-widget.poller"

WITH_POLLER=1
[[ "${1:-}" == "--widget-only" ]] && WITH_POLLER=0

# --- prerequisites --------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ swiftc not found. Install Xcode command line tools first:"
  echo "    xcode-select --install"
  exit 1
fi

# --- 1. build the widget --------------------------------------------------
echo "→ building widget…"
bash "$DIR/build.sh" >/dev/null
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$DIR/SessionWidget.app" "$APP_DEST"

# --- 2. widget launch agent ----------------------------------------------
mkdir -p "$LA"
cat > "$LA/$WIDGET_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WIDGET_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DEST/Contents/MacOS/SessionWidget</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/claude-session-widget.log</string>
  <key>StandardErrorPath</key><string>/tmp/claude-session-widget.log</string>
</dict>
</plist>
EOF
launchctl bootout  "gui/$UIDN/$WIDGET_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UIDN" "$LA/$WIDGET_LABEL.plist"
echo "✓ widget installed → $APP_DEST"

# --- 3. usage poller (optional) ------------------------------------------
if [[ "$WITH_POLLER" == "1" ]]; then
  # Must live outside ~/Documents or macOS TCC blocks launchd from reading it.
  mkdir -p "$HOME/.claude"
  cp "$DIR/session_usage_poll.py" "$POLLER_DEST"
  PY="$(command -v python3 || echo /usr/bin/python3)"
  cat > "$LA/$POLLER_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$POLLER_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$PY</string><string>$POLLER_DEST</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>ANTHROPIC_API_KEY</key><string></string></dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>600</integer>
  <key>StandardOutPath</key><string>/tmp/claude-session-usage.log</string>
  <key>StandardErrorPath</key><string>/tmp/claude-session-usage.log</string>
</dict>
</plist>
EOF
  launchctl bootout  "gui/$UIDN/$POLLER_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UIDN" "$LA/$POLLER_LABEL.plist"
  launchctl kickstart -k "gui/$UIDN/$POLLER_LABEL"
  echo "✓ poller installed (runs every 10 min, $PY)"
  sleep 2
  if [[ -f "$HOME/.claude/session-usage.json" ]]; then
    echo "✓ first poll wrote ~/.claude/session-usage.json"
  else
    echo "… no cache yet — it writes on the next run once you've used Claude Code."
    echo "  Check /tmp/claude-session-usage.log if it never appears."
  fi
else
  echo "• skipping poller (--widget-only): widget will show a transcript estimate."
fi

echo
echo "Done. The widget appears top-right (drag to move, right-click for menu)."
echo "Uninstall any time with ./uninstall.sh"
