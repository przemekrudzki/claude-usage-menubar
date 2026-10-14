#!/bin/zsh
# Keeps Claude Code's OAuth token in the Keychain fresh, so the menu bar app keeps working
# when only the Claude desktop app is in use (it does not renew that token; only the CLI does).
# Run every 5 minutes by launchd (see install-keepalive.sh); acts only when the token is near expiry.
set -u

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
THRESHOLD_MIN=10

minutes_left() {
  security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null |
    /usr/bin/python3 -I -c 'import json,sys,time; e=json.load(sys.stdin)["claudeAiOauth"]["expiresAt"]; print(int((e/1000-time.time())//60))' 2>/dev/null
}

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

left=$(minutes_left)
if [[ -z "$left" ]]; then
  log "could not read token expiry; skipping"
  exit 0
fi
(( left > THRESHOLD_MIN )) && exit 0

log "token has ${left} min left; trying 'claude auth status'"
cd "$HOME"
"$CLAUDE" auth status >/dev/null 2>&1
left=$(minutes_left)
if [[ -n "$left" ]] && (( left > THRESHOLD_MIN )); then
  log "renewed by auth status (${left} min left)"
  exit 0
fi

log "auth status did not renew; sending a one-word Haiku prompt"
"$CLAUDE" -p "ok" --model haiku --no-session-persistence >/dev/null 2>&1
left=$(minutes_left)
log "after prompt: ${left:-unknown} min left"
