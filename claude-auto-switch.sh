#!/bin/bash
# Claude Auto-Switch: Automatically rotates between Claude.ai accounts at utilization threshold
#
# Ensures continuous Claude Code availability by switching to the next account
# when the current account reaches the configured utilization threshold.
#
# Cycle:
#   1. Work on Account A
#   2. Account A hits threshold → switch to Account B → optional "pause" to Kitty terminal
#   3. Cache Account A's resets_at timestamp
#   4. Wait until (resets_at_A - resume_before_reset_hours)
#   5. Send "continue" to Kitty → work on Account B
#   6. Account B hits threshold → switch back to A (now reset) → repeat
#
# Runs every 60s via launchd. See README.md for setup instructions.

# Ensure Homebrew python3 is available
export PATH="/opt/homebrew/bin:$PATH"

CONFIG="$HOME/.claude/auto-switch-config.json"
CACHE="$HOME/.claude/stats-cache.json"
LOG="$HOME/.claude/auto-switch.log"
RESUME_PID_FILE="$HOME/.claude/auto-switch-resume.pid"
KITTY_BIN="/Applications/kitty.app/Contents/MacOS/kitty"

CLAUDE_JSON="$HOME/.claude.json"
KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="$(whoami)"
SETTINGS="$HOME/.claude/settings.json"
SETTINGS_PERSONAL="$HOME/.claude/settings-personal.json"

LOG_DEDUP_FILE="$HOME/.claude/auto-switch-last-log.txt"
LAST_POLL_FILE="$HOME/.claude/auto-switch-last-poll.json"

# ── Logging ──
log() {
  local MSG="$1"
  local NOW_S
  NOW_S=$(date +%s)

  # POLL/SKIP lines: only log if message changed OR 15min passed (suppress noise)
  if [[ "$MSG" == POLL:* ]] || [[ "$MSG" == SKIP:* ]]; then
    local LAST_MSG LAST_TIME
    if [ -f "$LOG_DEDUP_FILE" ]; then
      LAST_MSG=$(head -1 "$LOG_DEDUP_FILE" 2>/dev/null)
      LAST_TIME=$(tail -1 "$LOG_DEDUP_FILE" 2>/dev/null)
    fi
    if [ "$MSG" = "$LAST_MSG" ] && [ $(( NOW_S - ${LAST_TIME:-0} )) -lt 900 ]; then
      return
    fi
    printf '%s\n%s\n' "$MSG" "$NOW_S" > "$LOG_DEDUP_FILE"
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG"
  tail -5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# ── Config ──
read_config() {
  if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'EOF'
{
  "enabled": false,
  "threshold": 90,
  "kitty_pause_on_switch": false,
  "resume_before_reset_hours": 0.5,
  "accounts": [
    {"label": "account1", "email_pattern": "example1.com"},
    {"label": "account2", "email_pattern": "example2.com"}
  ],
  "active_account": "",
  "last_switch_time": 0,
  "other_account_resets_at": ""
}
EOF
    log "CONFIG: created default config at $CONFIG — edit it before enabling"
  fi
  ENABLED=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('enabled', False))" 2>/dev/null)
  THRESHOLD=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('threshold', 90))" 2>/dev/null)
  KITTY_PAUSE=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('kitty_pause_on_switch', False))" 2>/dev/null)
  RESUME_HOURS=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('resume_before_reset_hours', 0.5))" 2>/dev/null)
  LAST_SWITCH_TIME=$(python3 -c "import json; print(int(json.load(open('$CONFIG')).get('last_switch_time', 0)))" 2>/dev/null)
}

update_config() {
  python3 -c "
import json
d = json.load(open('$CONFIG'))
d['$1'] = $2
json.dump(d, open('$CONFIG', 'w'), indent=2)
"
}

# ── Account helpers ──
current_account_email() {
  python3 -c "
import json
d = json.load(open('$CLAUDE_JSON'))
print(d.get('oauthAccount', {}).get('emailAddress', 'unknown'))
" 2>/dev/null || echo "unknown"
}

# Match email to label via email_pattern entries in config
account_label() {
  local EMAIL="$1"
  python3 -c "
import json
d = json.load(open('$CONFIG'))
email = '$EMAIL'.lower()
for acc in d.get('accounts', []):
    pattern = acc.get('email_pattern', '').lower()
    if pattern and pattern in email:
        print(acc['label'])
        exit()
print('unknown')
" 2>/dev/null || echo "unknown"
}

# Return next account label in rotation (wraps around — supports N accounts)
next_label() {
  python3 -c "
import json
d = json.load(open('$CONFIG'))
accounts = [a['label'] for a in d.get('accounts', [])]
cur = '$1'
if cur not in accounts:
    print(accounts[0] if accounts else 'unknown')
else:
    idx = accounts.index(cur)
    print(accounts[(idx + 1) % len(accounts)])
" 2>/dev/null || echo "unknown"
}

claude_json_backup() { echo "$HOME/.claude.json.$1"; }
keychain_backup()    { echo "$HOME/.claude-keychain-$1.json"; }

credentials_ready() {
  local LABEL="$1"
  [ -f "$(claude_json_backup "$LABEL")" ] && [ -f "$(keychain_backup "$LABEL")" ]
}

save_current_credentials() {
  local LABEL="$1"
  cp "$CLAUDE_JSON" "$(claude_json_backup "$LABEL")"
  security find-generic-password -l "$KEYCHAIN_SERVICE" -w 2>/dev/null > "$(keychain_backup "$LABEL")"
}

restore_credentials() {
  local LABEL="$1"
  local JSON_FILE KEYCHAIN_FILE
  JSON_FILE=$(claude_json_backup "$LABEL")
  KEYCHAIN_FILE=$(keychain_backup "$LABEL")

  # Save current account first
  local CUR_LABEL
  CUR_LABEL=$(account_label "$(current_account_email)")
  [ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"

  # Restore target
  cp "$JSON_FILE" "$CLAUDE_JSON"
  local KEYCHAIN_DATA
  KEYCHAIN_DATA=$(cat "$KEYCHAIN_FILE")
  security delete-generic-password -l "$KEYCHAIN_SERVICE" 2>/dev/null
  security add-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" \
    -l "$KEYCHAIN_SERVICE" -w "$KEYCHAIN_DATA" 2>/dev/null
  cp "$SETTINGS_PERSONAL" "$SETTINGS"
}

# ── Kitty terminal helpers ──
find_kitty_socket() {
  # Adjust the glob pattern to match your kitty socket name (set in kitty.conf)
  local SOCK
  SOCK=$(ls /tmp/kitty-* 2>/dev/null | head -1)
  [ -n "$SOCK" ] && echo "unix:$SOCK" || echo ""
}

kitty_send() {
  local MSG="$1"
  local SOCK
  SOCK=$(find_kitty_socket)
  [ -z "$SOCK" ] && log "KITTY: no socket found" && return 1
  "$KITTY_BIN" @ --to "$SOCK" send-text "${MSG}"$'\r' 2>/dev/null
}

kill_resume_timer() {
  if [ -f "$RESUME_PID_FILE" ]; then
    local OLD_PID
    OLD_PID=$(cat "$RESUME_PID_FILE")
    kill "$OLD_PID" 2>/dev/null
    rm -f "$RESUME_PID_FILE" "$HOME/.claude/auto-switch-resume-time.txt"
  fi
}

schedule_resume() {
  local WAIT_SECONDS="$1"
  local RESUME_TIME="$2"
  kill_resume_timer
  (
    sleep "$WAIT_SECONDS"
    kitty_send "continue"
    log "RESUME: sent 'continue' to kitty (scheduled ${WAIT_SECONDS}s ago)"
    osascript -e 'display notification "Continue sent to Kitty — session resuming" with title "Claude Auto-Switch"' 2>/dev/null
    rm -f "$RESUME_PID_FILE" "$HOME/.claude/auto-switch-resume-time.txt"
  ) &
  echo $! > "$RESUME_PID_FILE"
  [ -n "$RESUME_TIME" ] && echo "$RESUME_TIME" > "$HOME/.claude/auto-switch-resume-time.txt"
}

# ── Adaptive polling: reduce API calls when utilization is low ──
should_poll() {
  local LAST_UTIL LAST_POLL_TIME
  if [ -f "$LAST_POLL_FILE" ]; then
    read -r LAST_UTIL LAST_POLL_TIME <<< $(python3 -c "
import json
d = json.load(open('$LAST_POLL_FILE'))
print(d.get('util', 0), d.get('time', 0))
" 2>/dev/null || echo "0 0")
  else
    echo "yes"; return
  fi
  local NOW ELAPSED INTERVAL
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_POLL_TIME))
  if   [ "$LAST_UTIL" -lt 10 ]; then INTERVAL=900   # <10%:   every 15 min
  elif [ "$LAST_UTIL" -lt 50 ]; then INTERVAL=300   # 10-49%: every 5 min
  else                                INTERVAL=60    # ≥50%:   every minute
  fi
  [ "$ELAPSED" -ge "$INTERVAL" ] && echo "yes" || echo "no"
}

# ── API: fetch utilization for a given Bearer token ──
get_token() {
  local LABEL="$1"
  python3 -c "
import json
f = '$(keychain_backup "$LABEL")'
print(json.loads(open(f).read().strip()).get('claudeAiOauth', {}).get('accessToken', ''))
" 2>/dev/null
}

fetch_usage() {
  local TOKEN="$1"
  [ -z "$TOKEN" ] && echo "-1 none" && return
  python3 -c "
import urllib.request, json
req = urllib.request.Request(
  'https://api.anthropic.com/api/oauth/usage',
  headers={
    'Authorization': 'Bearer $TOKEN',
    'Content-Type': 'application/json',
    'anthropic-beta': 'oauth-2025-04-20'
  }
)
try:
  with urllib.request.urlopen(req, timeout=10) as r:
    d = json.loads(r.read())
    if 'error' in d:
      print('-1 none')
    else:
      u = d.get('five_hour', {})
      util = u.get('utilization')
      if util is None:
        print('-1 none')
      else:
        print(int(util), u.get('resets_at', '') or 'none')
except:
  print('-1 none')
" 2>/dev/null || echo "-1 none"
}

# ── Main ──
read_config

[ "$ENABLED" != "True" ] && exit 0
[ "$(should_poll)" != "yes" ] && exit 0

# Get current account
CUR_EMAIL=$(current_account_email)
CUR_LABEL=$(account_label "$CUR_EMAIL")
TARGET=$(next_label "$CUR_LABEL")

# Fetch usage for current account
CUR_TOKEN=$(get_token "$CUR_LABEL")
read -r UTIL RESETS_AT <<< $(fetch_usage "$CUR_TOKEN")

if [ "$UTIL" -eq -1 ] 2>/dev/null; then
  # API failed — use cached value, skip poll timer update
  log "POLL: API error for $CUR_LABEL — using cache"
  read -r UTIL RESETS_AT <<< $(python3 -c "
import json
d = json.load(open('$CACHE'))
u = d.get('usage', {}).get('five_hour', {})
print(int(u.get('utilization', 0)), u.get('resets_at', '') or 'none')
" 2>/dev/null || echo "0 none")
else
  # Success — update cache + poll timer + refresh active account backup (keeps token fresh)
  python3 -c "
import json, time
now = int(time.time())
d = {'usage': {'five_hour': {'utilization': $UTIL, 'resets_at': '$RESETS_AT' if '$RESETS_AT' != 'none' else None}}, 'timestamp': int(time.time() * 1000)}
json.dump(d, open('$CACHE', 'w'), indent=2)
json.dump({'util': $UTIL, 'time': now}, open('$LAST_POLL_FILE', 'w'))
" 2>/dev/null
  save_current_credentials "$CUR_LABEL"
fi

log "POLL: $CUR_LABEL=${UTIL}%"

# Cooldown: no switch within 5 minutes of the last switch
NOW=$(date +%s)
ELAPSED=$((NOW - LAST_SWITCH_TIME))
[ "$ELAPSED" -lt 300 ] && exit 0

# ── Threshold check → Switch ──
if [ "$UTIL" -ge "$THRESHOLD" ]; then

  if ! credentials_ready "$TARGET"; then
    log "SKIP: $TARGET credentials not ready (util=$UTIL%)"
    osascript -e "display notification \"Auto-Switch: credentials for '$TARGET' missing\" with title \"Claude Auto-Switch\"" 2>/dev/null
    exit 0
  fi

  # Check if target token is expired
  TOKEN_EXPIRED=$(python3 -c "
import json, time
f = '$(keychain_backup "$TARGET")'
d = json.load(open(f))
expires_ms = d.get('claudeAiOauth', {}).get('expiresAt', 0)
print('yes' if time.time() > expires_ms / 1000 else 'no')
" 2>/dev/null || echo "unknown")

  if [ "$TOKEN_EXPIRED" = "yes" ]; then
    log "SKIP: $TARGET token EXPIRED — manual /login required"
    osascript -e "display notification \"⚠️ $TARGET token expired — please /login\" with title \"Claude Auto-Switch\"" 2>/dev/null
    exit 0
  fi

  # Fetch target account usage (only when current is at threshold — saves API calls)
  TARGET_TOKEN=$(get_token "$TARGET")
  read -r TARGET_UTIL TARGET_RESETS_AT <<< $(fetch_usage "$TARGET_TOKEN")

  if [ "$TARGET_UTIL" -eq -1 ] 2>/dev/null; then
    # API failed for target — assume available, proceed (worst case caught next cycle)
    log "WARN: API failed for $TARGET — assuming available, proceeding with switch"
    TARGET_UTIL=0
    TARGET_RESETS_AT="none"
  fi

  if [ "$TARGET_UTIL" -ge "$THRESHOLD" ]; then
    if [ "$TARGET_RESETS_AT" != "none" ]; then
      MINS_TO_RESET=$(python3 -c "
from dateutil.parser import parse
from datetime import datetime, timezone
r = parse('$TARGET_RESETS_AT')
print(max(0, int((r - datetime.now(timezone.utc)).total_seconds() / 60)))
" 2>/dev/null || echo "?")
    else
      MINS_TO_RESET="?"
    fi
    log "SKIP: both accounts at limit — $CUR_LABEL=${UTIL}% $TARGET=${TARGET_UTIL}% (resets in ${MINS_TO_RESET}m)"
    osascript -e "display notification \"Both accounts at limit — $TARGET resets in ${MINS_TO_RESET} min\" with title \"Claude Auto-Switch\"" 2>/dev/null
    exit 0
  fi

  # ── Perform the switch ──
  log "SWITCH: $CUR_LABEL → $TARGET (util=$UTIL% >= threshold=$THRESHOLD%, target=${TARGET_UTIL}%)"

  restore_credentials "$TARGET"
  update_config "active_account" "\"$TARGET\""
  update_config "last_switch_time" "$NOW"

  # Calculate wait time BEFORE deciding whether to pause
  SHOULD_PAUSE=false
  WAIT_SECONDS=0
  RESUME_TIME=""

  if [ "$RESETS_AT" != "none" ]; then
    WAIT_SECONDS=$(python3 -c "
from dateutil.parser import parse
from datetime import datetime, timezone, timedelta
resets = parse('$RESETS_AT')
lead = timedelta(hours=$RESUME_HOURS)
resume_at = resets - lead
wait = (resume_at - datetime.now(timezone.utc)).total_seconds()
print(max(0, int(wait)))
" 2>/dev/null || echo "0")

    if [ "$WAIT_SECONDS" -gt 120 ]; then
      SHOULD_PAUSE=true
      RESUME_TIME=$(python3 -c "
from dateutil.parser import parse
from datetime import timedelta
resets = parse('$RESETS_AT')
resume = resets - timedelta(hours=$RESUME_HOURS)
print(resume.astimezone().strftime('%H:%M'))
" 2>/dev/null || echo "?")
    fi
  fi

  if [ "$KITTY_PAUSE" = "True" ] && [ "$SHOULD_PAUSE" = "true" ]; then
    PAUSE_MSG='pause now and only continue when I say continue, even if agent results come in. Do not pause on your own anytime, only when you receive this message. continue on "continue"'
    (
      sleep 60
      kitty_send "$PAUSE_MSG"
      log "KITTY: sent pause message (60s after switch)"
    ) &

    schedule_resume "$WAIT_SECONDS" "$RESUME_TIME"
    log "TIMER: 'continue' scheduled in ${WAIT_SECONDS}s (at $RESUME_TIME)"
    osascript -e "display notification \"Auto-Switch: → $TARGET · Paused · Continue at $RESUME_TIME\" with title \"Claude Auto-Switch\"" 2>/dev/null

  elif [ "$KITTY_PAUSE" = "True" ]; then
    log "SKIP-PAUSE: reset too soon (${WAIT_SECONDS}s) — switching without pause"
    osascript -e "display notification \"Auto-Switch: → $TARGET (reset imminent, no pause)\" with title \"Claude Auto-Switch\"" 2>/dev/null

  else
    osascript -e "display notification \"Auto-Switch: switched to $TARGET (${UTIL}% limit reached)\" with title \"Claude Auto-Switch\"" 2>/dev/null
  fi
fi
