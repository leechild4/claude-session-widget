#!/usr/bin/env bash
# Remove the Claude Session Widget and the usage poller. Per-user, no sudo.
set -euo pipefail

UIDN="$(id -u)"
LA="$HOME/Library/LaunchAgents"

for label in com.claude-session-widget.app com.claude-session-widget.poller; do
  launchctl bootout "gui/$UIDN/$label" 2>/dev/null || true
  rm -f "$LA/$label.plist"
done

rm -rf "$HOME/Applications/SessionWidget.app"
rm -f  "$HOME/.claude/session_usage_poll.py"
rm -f  "$HOME/.claude/session-usage.json"
rm -f  /tmp/claude-session-widget.log /tmp/claude-session-usage.log

echo "✓ Uninstalled. (Your ~/.claude transcripts and Claude Code login are untouched.)"
