#!/bin/zsh
# Installs (or reinstalls) the launchd agent that runs token-keepalive.sh every 5 minutes
# and at login. Uninstall: launchctl bootout gui/$UID/<LABEL> && rm <PLIST>
set -euo pipefail

LABEL=io.github.przemekrudzki.claude-usage.token-keepalive
SCRIPT="$(cd "$(dirname "$0")" && pwd)/token-keepalive.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/claude-usage-token-keepalive.log"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod +x "$SCRIPT"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$SCRIPT</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed $LABEL (log: $LOG)"
