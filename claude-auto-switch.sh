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

# Ensure Homebrew python3 is available (macOS with Homebrew)
[ -d /opt/homebrew/bin ] && export PATH="/opt/homebrew/bin:$PATH"

OS_TYPE="$(uname -s)"  # Darwin or Linux

CONFIG="$HOME/.claude/auto-switch-config.json"
CACHE="$HOME/.claude/stats-cache.json"
USAGE_CACHE="$HOME/.claude/account-usage-cache.json"
LOG="$HOME/.claude/auto-switch.log"
REFRESH_AUDIT_LOG="$HOME/.claude/auto-switch-refresh-audit.log"
SESSION_STATE="$HOME/.claude/session-autostart-state.json"
RESUME_PID_FILE="$HOME/.claude/auto-switch-resume.pid"
# Kitty binary: macOS app bundle or Linux PATH
if [ "$OS_TYPE" = "Darwin" ]; then
  KITTY_BIN="/Applications/kitty.app/Contents/MacOS/kitty"
else
  KITTY_BIN="$(command -v kitty 2>/dev/null || echo kitty)"
fi
CLAUDE_BIN="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"

CLAUDE_JSON="$HOME/.claude.json"
# Linux: Claude Code stores the token in ~/.claude/.credentials.json instead of macOS Keychain
LINUX_CREDENTIALS="$HOME/.claude/.credentials.json"
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
  "session_autostart_enabled": false,
  "session_autostart_threshold": 70,
  "session_autostart_hour": 6,
  "session_autostart_prompt": "test",
  "session_autostart_model": "haiku",
  "session_autostart_allowed_tools": "Read",
  "session_autostart_max_turns": 1,
  "session_autostart_output_format": "json",
  "accounts": [
    {"label": "account1@example.com"},
    {"label": "account2@example.com"}
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
  SESSION_AUTOSTART_ENABLED=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('session_autostart_enabled', False))" 2>/dev/null)
  SESSION_AUTOSTART_THRESHOLD=$(python3 -c "import json; print(int(json.load(open('$CONFIG')).get('session_autostart_threshold', 70)))" 2>/dev/null)
  SESSION_AUTOSTART_HOUR=$(python3 -c "import json; print(int(json.load(open('$CONFIG')).get('session_autostart_hour', 6)))" 2>/dev/null)
  SESSION_AUTOSTART_PROMPT=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('session_autostart_prompt', 'test'))" 2>/dev/null)
  SESSION_AUTOSTART_MODEL=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('session_autostart_model', 'haiku'))" 2>/dev/null)
  SESSION_AUTOSTART_ALLOWED_TOOLS=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('session_autostart_allowed_tools', 'Read'))" 2>/dev/null)
  SESSION_AUTOSTART_MAX_TURNS=$(python3 -c "import json; print(int(json.load(open('$CONFIG')).get('session_autostart_max_turns', 1)))" 2>/dev/null)
  SESSION_AUTOSTART_OUTPUT_FORMAT=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('session_autostart_output_format', 'json'))" 2>/dev/null)
  PREFERRED_RETURN_THRESHOLD=$(python3 -c "import json; print(int(json.load(open('$CONFIG')).get('preferred_return_threshold', 70)))" 2>/dev/null)
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

all_account_labels() {
  python3 -c "
import json
d = json.load(open('$CONFIG'))
for account in d.get('accounts', []):
  label = account.get('label', '')
  if label:
    print(label)
" 2>/dev/null
}

update_usage_cache() {
  local LABEL="$1"
  local UTIL="$2"
  local RESETS_AT="$3"
  local STATUS="$4"
  local SOURCE="$5"
  local SEVEN_DAY_UTIL="$6"
  local SEVEN_DAY_RESETS_AT="$7"
  python3 -c "
import json, os, time
path = '$USAGE_CACHE'
state = {'accounts': {}, 'cursor': -1}
if os.path.exists(path):
  try:
    state = json.load(open(path))
  except Exception:
    state = {'accounts': {}, 'cursor': -1}
accounts = state.setdefault('accounts', {})
entry = accounts.setdefault('$LABEL', {})
entry['label'] = '$LABEL'
if '$UTIL' != '__KEEP__':
  try:
    entry['utilization'] = int(float('$UTIL'))
  except Exception:
    entry['utilization'] = None
elif '$STATUS' != 'ok':
  entry['utilization'] = None
if '$RESETS_AT' != '__KEEP__':
  entry['resets_at'] = '' if '$RESETS_AT' == 'none' else '$RESETS_AT'
elif '$STATUS' != 'ok':
  entry['resets_at'] = ''
if '$SEVEN_DAY_UTIL' != '__KEEP__':
  try:
    entry['seven_day_utilization'] = int(float('$SEVEN_DAY_UTIL'))
  except Exception:
    entry['seven_day_utilization'] = None
elif '$STATUS' != 'ok':
  entry['seven_day_utilization'] = None
if '$SEVEN_DAY_RESETS_AT' != '__KEEP__':
  entry['seven_day_resets_at'] = '' if '$SEVEN_DAY_RESETS_AT' == 'none' else '$SEVEN_DAY_RESETS_AT'
elif '$STATUS' != 'ok':
  entry['seven_day_resets_at'] = ''
entry['status'] = '$STATUS'
entry['source'] = '$SOURCE'
entry['checked_at'] = int(time.time() * 1000)
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

next_usage_refresh_label() {
  local CURRENT_LABEL="$1"
  python3 -c "
import json, os
cfg = json.load(open('$CONFIG'))
labels = [a.get('label', '') for a in cfg.get('accounts', []) if a.get('label', '') and a.get('label', '') != '$CURRENT_LABEL']
if not labels:
  print('')
  raise SystemExit(0)
path = '$USAGE_CACHE'
state = {'accounts': {}, 'cursor': -1}
if os.path.exists(path):
  try:
    state = json.load(open(path))
  except Exception:
    state = {'accounts': {}, 'cursor': -1}
cursor = int(state.get('cursor', -1))
cursor = (cursor + 1) % len(labels)
state['cursor'] = cursor
json.dump(state, open(path, 'w'), indent=2)
print(labels[cursor])
" 2>/dev/null
}

# ── Account helpers ──
current_account_email() {
  python3 -c "
import json
d = json.load(open('$CLAUDE_JSON'))
print(d.get('oauthAccount', {}).get('emailAddress', 'unknown'))
" 2>/dev/null || echo "unknown"
}

# Email IS the label — no pattern matching needed
account_label() {
  local EMAIL="$1"
  echo "$EMAIL"
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

preferred_return_label() {
  local CURRENT_LABEL="$1"
  local CURRENT_UTIL="$2"
  local LIMIT="$3"
  python3 -c "
import json, os

cfg_path = '$CONFIG'
cache_path = '$USAGE_CACHE'
current_label = '$CURRENT_LABEL'
current_util_raw = '$CURRENT_UTIL'
limit = int('$LIMIT')

try:
    labels = [a.get('label', '') for a in json.load(open(cfg_path)).get('accounts', []) if a.get('label', '')]
except Exception:
    labels = []

cache = {'accounts': {}}
if os.path.exists(cache_path):
    try:
        cache = json.load(open(cache_path))
    except Exception:
        cache = {'accounts': {}}

entries = cache.get('accounts', {})

def eligible(label):
    if label == current_label:
        try:
            util = int(current_util_raw)
        except Exception:
            return False
        return 0 <= util < limit
    entry = entries.get(label, {})
    if entry.get('status', '') != 'ok':
        return False
    util = entry.get('utilization')
    return isinstance(util, int) and util < limit

for label in labels:
    if eligible(label):
        print(label)
        break
" 2>/dev/null
}

find_ordered_switch_target() {
  local CURRENT_LABEL="$1"
  local LIMIT="$2"
  while IFS= read -r LABEL; do
    [ -z "$LABEL" ] && continue
    [ "$LABEL" = "$CURRENT_LABEL" ] && continue
    if ! credentials_ready "$LABEL"; then
      update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "missing_credentials" "ordered-target"
      continue
    fi
    local TOKEN STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT
    TOKEN=$(get_token "$LABEL")
    read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT <<< $(fetch_usage_detailed "$TOKEN")
    if [ "$STATUS" = "ok" ]; then
      update_usage_cache "$LABEL" "$UTIL" "$RESETS_AT" "ok" "ordered-target" "$SEVEN_DAY_UTIL" "$SEVEN_DAY_RESETS_AT"
      if [ "$UTIL" -lt "$LIMIT" ] 2>/dev/null; then
        echo "$LABEL|$UTIL|$RESETS_AT"
        return 0
      fi
    else
      update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "$STATUS" "ordered-target" "__KEEP__" "__KEEP__"
    fi
  done < <(all_account_labels)
  return 1
}

perform_switch() {
  local CURRENT_LABEL="$1"
  local CURRENT_UTIL="$2"
  local CURRENT_RESETS_AT="$3"
  local TARGET="$4"
  local TARGET_UTIL="$5"
  local NOW="$6"
  local REASON="$7"
  local SESSION_LINE=""
  local CURRENT_SESSION_PID=""
  local CURRENT_SESSION_ID=""
  local CURRENT_SESSION_CWD=""
  local CURRENT_SESSION_MODEL=""

  log "SWITCH: $CURRENT_LABEL → $TARGET ($REASON, current=${CURRENT_UTIL}%, target=${TARGET_UTIL}%)"

  restore_credentials "$TARGET"
  update_config "active_account" "\"$TARGET\""
  update_config "last_switch_time" "$NOW"

  SHOULD_PAUSE=false
  WAIT_SECONDS=0
  RESUME_TIME=""

  if [ "$CURRENT_RESETS_AT" != "none" ]; then
    WAIT_SECONDS=$(python3 -c "
from dateutil.parser import parse
from datetime import datetime, timezone, timedelta
resets = parse('$CURRENT_RESETS_AT')
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
resets = parse('$CURRENT_RESETS_AT')
resume = resets - timedelta(hours=$RESUME_HOURS)
print(resume.astimezone().strftime('%H:%M'))
" 2>/dev/null || echo "?")
    fi
  fi

  if [ "$KITTY_PAUSE" = "True" ] && [ "$SHOULD_PAUSE" = "true" ]; then
    SESSION_LINE=$(resolve_active_session_for_cwd "$PWD")
    IFS=$'\t' read -r CURRENT_SESSION_PID CURRENT_SESSION_ID CURRENT_SESSION_CWD CURRENT_SESSION_MODEL _ _ <<< "$SESSION_LINE"
    PAUSE_MSG='pause now and only continue when I say continue, even if agent results come in. Do not pause on your own anytime, only when you receive this message. continue on "continue"'
    (
      sleep 60
      if [ -n "$CURRENT_SESSION_ID" ] && [ -n "$CURRENT_SESSION_MODEL" ] && [ -n "$CURRENT_SESSION_CWD" ]; then
        if resume_session_with_prompt "$CURRENT_SESSION_ID" "$CURRENT_SESSION_MODEL" "$CURRENT_SESSION_CWD" "$PAUSE_MSG"; then
          log "SESSION: sent pause message to $CURRENT_SESSION_ID (60s after switch)"
        else
          kitty_send "$PAUSE_MSG"
          log "KITTY: session pause failed, sent pause message via kitty fallback"
        fi
      else
        kitty_send "$PAUSE_MSG"
        log "KITTY: sent pause message (60s after switch)"
      fi
    ) &

    schedule_resume "$WAIT_SECONDS" "$RESUME_TIME" "$CURRENT_SESSION_ID" "$CURRENT_SESSION_MODEL" "$CURRENT_SESSION_CWD"
    log "TIMER: 'continue' scheduled in ${WAIT_SECONDS}s (at $RESUME_TIME)"
    osascript -e "display notification \"Auto-Switch: → $TARGET · Paused · Continue at $RESUME_TIME\" with title \"Claude Auto-Switch\"" 2>/dev/null
  elif [ "$KITTY_PAUSE" = "True" ]; then
    log "SKIP-PAUSE: reset too soon (${WAIT_SECONDS}s) — switching without pause"
    osascript -e "display notification \"Auto-Switch: → $TARGET (reset imminent, no pause)\" with title \"Claude Auto-Switch\"" 2>/dev/null
  else
    if [ "$REASON" = "priority-return" ]; then
      osascript -e "display notification \"Auto-Switch: back to $TARGET (${TARGET_UTIL}% in priority order)\" with title \"Claude Auto-Switch\"" 2>/dev/null
    else
      osascript -e "display notification \"Auto-Switch: switched to $TARGET (${CURRENT_UTIL}% limit reached)\" with title \"Claude Auto-Switch\"" 2>/dev/null
    fi
  fi
}

claude_json_backup() { echo "$HOME/.claude.json.$1"; }
keychain_backup()    { echo "$HOME/.claude-keychain-$1.json"; }
backup_meta()        { echo "$HOME/.claude-meta-$1.json"; }

write_backup_metadata() {
  local LABEL="$1"
  local REASON="${2:-save}"
  python3 -c "
import hashlib, json, os, socket, time

label = '$LABEL'
json_path = '$(claude_json_backup "$LABEL")'
cred_path = '$(keychain_backup "$LABEL")'
meta_path = '$(backup_meta "$LABEL")'
host = socket.gethostname()
email = 'unknown'
expires_at = None
refresh_hash = ''

try:
  email = json.load(open(json_path)).get('oauthAccount', {}).get('emailAddress', 'unknown')
except Exception:
  pass

try:
  credential = json.load(open(cred_path))
  oauth = credential.get('claudeAiOauth', {})
  expires_at = oauth.get('expiresAt')
  refresh_token = oauth.get('refreshToken', '')
  refresh_hash = hashlib.sha256(refresh_token.encode()).hexdigest()[:16] if refresh_token else ''
except Exception:
  pass

metadata = {
  'label': label,
  'email': email,
  'saved_at': int(time.time()),
  'saved_from_host': host,
  'reason': '$REASON',
  'expires_at': expires_at,
  'refresh_hash': refresh_hash,
  'json_path': json_path,
  'credential_path': cred_path,
}
json.dump(metadata, open(meta_path, 'w'), indent=2)
" 2>/dev/null
}

audit_refresh_event() {
  local LABEL="$1"
  local MESSAGE="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $LABEL $MESSAGE" >> "$REFRESH_AUDIT_LOG"
  tail -5000 "$REFRESH_AUDIT_LOG" > "$REFRESH_AUDIT_LOG.tmp" 2>/dev/null && mv "$REFRESH_AUDIT_LOG.tmp" "$REFRESH_AUDIT_LOG" 2>/dev/null
}

session_window_started() {
  local LABEL="$1"
  local RESETS_AT="$2"
  python3 -c "
import json, os
path = '$SESSION_STATE'
if not os.path.exists(path):
    print('no')
    raise SystemExit(0)
state = json.load(open(path))
started = state.get('started_windows', {})
print('yes' if started.get('$LABEL', '') == '$RESETS_AT' else 'no')
" 2>/dev/null || echo "no"
}

mark_session_started() {
  local LABEL="$1"
  local RESETS_AT="$2"
  local REASON="$3"
  local RUN_LOG="$4"
  python3 -c "
import json, os, time
path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
started = state.setdefault('started_windows', {})
if '$RESETS_AT' and '$RESETS_AT' != 'none':
    started['$LABEL'] = '$RESETS_AT'
sessions = state.setdefault('sessions', {})
sessions['$LABEL'] = {
    'reset_at': '' if '$RESETS_AT' == 'none' else '$RESETS_AT',
    'reason': '$REASON',
    'log': '$RUN_LOG',
    'started_at': int(time.time())
}
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

# Refresh token for a backup credential file using OAuth2 refresh_token grant
refresh_backup_token() {
  local LABEL="$1"
  local KEYCHAIN_FILE
  KEYCHAIN_FILE=$(keychain_backup "$LABEL")
  [ ! -f "$KEYCHAIN_FILE" ] && return 1

  python3 -c "
import hashlib, json, urllib.request, urllib.error, os, time

KEYCHAIN_FILE = '$KEYCHAIN_FILE'
CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
TOKEN_URL = 'https://api.anthropic.com/v1/oauth/token'

cred = json.loads(open(KEYCHAIN_FILE).read())
oauth = cred.get('claudeAiOauth', {})
refresh_token = oauth.get('refreshToken', '')
expires_at = oauth.get('expiresAt', 0)
refresh_hash = hashlib.sha256(refresh_token.encode()).hexdigest()[:16] if refresh_token else ''

if not refresh_token:
    print('REFRESH_FAILED: reason=no_refresh_token refresh_hash=none')
    raise SystemExit(1)

now_ms = int(time.time() * 1000)
hours_left = (expires_at - now_ms) / 3600000
if hours_left > 2:
    print(f'SKIP_REFRESH: hours_left={hours_left:.1f} refresh_hash={refresh_hash}')
    raise SystemExit(0)

data = json.dumps({
    'grant_type': 'refresh_token',
    'refresh_token': refresh_token,
    'client_id': CLIENT_ID
}).encode()
req = urllib.request.Request(TOKEN_URL, data=data, headers={
    'content-type': 'application/json',
    'anthropic-beta': 'oauth-2025-04-20',
})

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read())
    rotated = 'yes' if result.get('refresh_token', '') != refresh_token else 'no'
    cred['claudeAiOauth']['accessToken'] = result['access_token']
    cred['claudeAiOauth']['refreshToken'] = result['refresh_token']
    cred['claudeAiOauth']['expiresAt'] = now_ms + result['expires_in'] * 1000
    open(KEYCHAIN_FILE, 'w').write(json.dumps(cred))
    print(f'REFRESHED hours_left={hours_left:.1f} new_hours={result["expires_in"]/3600:.1f} rotated={rotated} refresh_hash={refresh_hash}')
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8', 'replace')[:300]
    try:
        parsed = json.loads(body)
        if isinstance(parsed, dict):
            reason = parsed.get('error_description') or parsed.get('error') or parsed.get('message') or body
        else:
            reason = body
    except Exception:
        reason = body
    print(f'REFRESH_FAILED: status={e.code} reason={reason} refresh_hash={refresh_hash}')
    raise SystemExit(1)
except Exception as e:
    print(f'REFRESH_FAILED: exception={type(e).__name__} detail={e} refresh_hash={refresh_hash}')
    raise SystemExit(1)
" 2>/dev/null
}

# Refresh all backup tokens that are expiring soon
refresh_all_tokens() {
  local CURRENT_LABEL
  CURRENT_LABEL=$(account_label "$(current_account_email)")
  for f in "$HOME"/.claude-keychain-*.json; do
    [ ! -f "$f" ] && continue
    local LABEL
    LABEL=$(echo "$f" | sed "s|.*\.claude-keychain-\(.*\)\.json|\1|")
    local RESULT
    RESULT=$(refresh_backup_token "$LABEL" 2>&1)
    if [ -n "$RESULT" ]; then
      log "TOKEN: $LABEL: $RESULT"
      audit_refresh_event "$LABEL" "$RESULT"
      case "$RESULT" in
        *"Refresh token not found or invalid"*|*"reason=no_refresh_token"*)
          if [ "$LABEL" != "$CURRENT_LABEL" ]; then
            local TOKEN STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT
            TOKEN=$(get_token_raw "$LABEL")
            read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT <<< $(fetch_usage_detailed "$TOKEN")
            if [ "$STATUS" = "ok" ]; then
              update_usage_cache "$LABEL" "$UTIL" "$RESETS_AT" "ok" "backup" "$SEVEN_DAY_UTIL" "$SEVEN_DAY_RESETS_AT"
            elif [ "$STATUS" = "rate_limited" ]; then
              update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "rate_limited" "backup" "__KEEP__" "__KEEP__"
            else
              update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "unauthorized" "refresh-audit"
            fi
          fi
          ;;
      esac
      case "$RESULT" in
        REFRESHED*|SKIP_REFRESH*) write_backup_metadata "$LABEL" "refresh" ;;
      esac
    fi
  done
}

get_token_raw() {
  local LABEL="$1"
  local CURRENT_LABEL
  CURRENT_LABEL=$(account_label "$(current_account_email)")
  python3 -c "
import json
label = '$LABEL'
current_label = '$CURRENT_LABEL'
live_file = '$LINUX_CREDENTIALS'
backup_file = '$(keychain_backup "$LABEL")'
f = live_file if '$OS_TYPE' == 'Linux' and label == current_label and __import__('os').path.exists(live_file) else backup_file
print(json.loads(open(f).read().strip()).get('claudeAiOauth', {}).get('accessToken', ''))
" 2>/dev/null
}

fetch_usage_detailed() {
  local TOKEN="$1"
  [ -z "$TOKEN" ] && echo "missing_token none none none none" && return
  python3 -c "
import json, urllib.request, urllib.error
token = '$TOKEN'
req = urllib.request.Request(
  'https://api.anthropic.com/api/oauth/usage',
  headers={
    'Authorization': f'Bearer {token}',
    'Content-Type': 'application/json',
    'anthropic-beta': 'oauth-2025-04-20'
  }
)
try:
  with urllib.request.urlopen(req, timeout=10) as response:
    payload = json.loads(response.read())
  window = payload.get('five_hour') or payload.get('usage', {}).get('five_hour') or {}
  seven_day = payload.get('seven_day') or payload.get('usage', {}).get('seven_day') or {}
  util = window.get('utilization')
  reset_at = window.get('resets_at', '') or 'none'
  seven_day_util = seven_day.get('utilization')
  seven_day_reset_at = seven_day.get('resets_at', '') or 'none'
  if util is None:
    print('missing_window none none none none')
  else:
    seven_day_text = 'none' if seven_day_util is None else int(float(seven_day_util))
    print('ok', int(float(util)), reset_at, seven_day_text, seven_day_reset_at)
except urllib.error.HTTPError as error:
  if error.code == 429:
    print('rate_limited none none none none')
  elif error.code == 401:
    print('unauthorized none none none none')
  else:
    print(f'http_{error.code} none none none none')
except Exception:
  print('request_failed none none none none')
" 2>/dev/null || echo "request_failed none none none none"
}

claude_process_running() {
  pgrep -f '(^|/)claude($| )' >/dev/null 2>&1
}

mark_session_autostart() {
  local LABEL="$1"
  local DAY_KEY="$2"
  local WINDOW_KEY="$3"
  python3 -c "
import json, os
path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
state.setdefault('last_day_keys', {})['$LABEL'] = '$DAY_KEY'
state.setdefault('last_window_keys', {})['$LABEL'] = '$WINDOW_KEY'
state['last_day_key'] = '$DAY_KEY'
state['last_window_key'] = '$WINDOW_KEY'
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

schedule_session_after_reset() {
  local LABEL="$1"
  local UTIL="$2"
  local RESETS_AT="$3"

  [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && return 0
  [ "$RESETS_AT" = "none" ] && return 0
  [ "$UTIL" -lt "$SESSION_AUTOSTART_THRESHOLD" ] 2>/dev/null && return 0

  local CHANGED
  CHANGED=$(python3 -c "
import json, os
path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
scheduled = state.setdefault('scheduled_resets', {})
current = scheduled.get('$LABEL', '')
changed = current != '$RESETS_AT'
scheduled['$LABEL'] = '$RESETS_AT'
json.dump(state, open(path, 'w'), indent=2)
print('yes' if changed else 'no')
" 2>/dev/null || echo "no")

  [ "$CHANGED" = "yes" ] && log "SESSION: scheduled reset autostart for $LABEL at $RESETS_AT (util=${UTIL}%)"
}

start_background_session() {
  local LABEL="$1"
  local UTIL="$2"
  local RESETS_AT="$3"
  local REASON="$4"

  local RUN_LOG
  RUN_LOG="$HOME/.claude/session-autostart-$(date +%s).log"
  nohup "$CLAUDE_BIN" -p "$SESSION_AUTOSTART_PROMPT" \
    --model "$SESSION_AUTOSTART_MODEL" \
    --allowedTools "$SESSION_AUTOSTART_ALLOWED_TOOLS" \
    --max-turns "$SESSION_AUTOSTART_MAX_TURNS" \
    --output-format "$SESSION_AUTOSTART_OUTPUT_FORMAT" \
    > "$RUN_LOG" 2>&1 &

  mark_session_autostart "$LABEL" "$(date +%F)" "$RESETS_AT"
  python3 -c "
import json, os
path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
scheduled = state.setdefault('scheduled_resets', {})
scheduled.pop('$LABEL', None)
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
  mark_session_started "$LABEL" "$RESETS_AT" "$REASON" "$RUN_LOG"
  log "SESSION: started cheap claude run for $LABEL ($REASON, util=${UTIL}%, log=$RUN_LOG)"
}

run_sync_session_for_label() {
  local LABEL="$1"
  local UTIL="$2"
  local RESETS_AT="$3"
  local REASON="$4"
  local RUN_LOG
  RUN_LOG="$HOME/.claude/session-autostart-${LABEL//[^A-Za-z0-9._-]/_}-$(date +%s).log"
  "$CLAUDE_BIN" -p "$SESSION_AUTOSTART_PROMPT" \
    --model "$SESSION_AUTOSTART_MODEL" \
    --allowedTools "$SESSION_AUTOSTART_ALLOWED_TOOLS" \
    --max-turns "$SESSION_AUTOSTART_MAX_TURNS" \
    --output-format "$SESSION_AUTOSTART_OUTPUT_FORMAT" \
    > "$RUN_LOG" 2>&1
  mark_session_autostart "$LABEL" "$(date +%F)" "$RESETS_AT"
  mark_session_started "$LABEL" "$RESETS_AT" "$REASON" "$RUN_LOG"
  log "SESSION: completed sync claude run for $LABEL ($REASON, util=${UTIL}%, log=$RUN_LOG)"
}

refresh_next_usage_cache() {
  local CURRENT_LABEL="$1"
  local NEXT_LABEL
  NEXT_LABEL=$(next_usage_refresh_label "$CURRENT_LABEL")
  [ -z "$NEXT_LABEL" ] && return 0
  local TOKEN STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT
  TOKEN=$(get_token "$NEXT_LABEL")
  read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT <<< $(fetch_usage_detailed "$TOKEN")
  if [ "$STATUS" = "ok" ]; then
    update_usage_cache "$NEXT_LABEL" "$UTIL" "$RESETS_AT" "ok" "backup" "$SEVEN_DAY_UTIL" "$SEVEN_DAY_RESETS_AT"
  else
    update_usage_cache "$NEXT_LABEL" "__KEEP__" "__KEEP__" "$STATUS" "backup" "__KEEP__" "__KEEP__"
  fi
}

refresh_all_usage_cache() {
  while IFS= read -r LABEL; do
    [ -z "$LABEL" ] && continue
    if ! credentials_ready "$LABEL"; then
      update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "missing_credentials" "full-refresh"
      continue
    fi
    local TOKEN STATUS UTIL RESETS_AT SOURCE
    TOKEN=$(get_token "$LABEL")
    read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT <<< $(fetch_usage_detailed "$TOKEN")
    SOURCE="backup"
    [ "$LABEL" = "$(account_label "$(current_account_email)")" ] && SOURCE="live"
    if [ "$STATUS" = "ok" ]; then
      update_usage_cache "$LABEL" "$UTIL" "$RESETS_AT" "ok" "$SOURCE" "$SEVEN_DAY_UTIL" "$SEVEN_DAY_RESETS_AT"
    else
      update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "$STATUS" "$SOURCE" "__KEEP__" "__KEEP__"
    fi
  done < <(all_account_labels)
}

start_all_sessions() {
  [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && log "SESSION: start-all skipped — session autostart disabled" && return 0
  local STARTED_COUNT=0
  local SKIPPED_COUNT=0
  while IFS= read -r LABEL; do
    [ -z "$LABEL" ] && continue
    if ! credentials_ready "$LABEL"; then
      log "SESSION: start-all skip $LABEL — credentials missing"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    local TOKEN STATUS UTIL RESETS_AT
    TOKEN=$(get_token "$LABEL")
      read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT <<< $(fetch_usage_detailed "$TOKEN")
    if [ "$STATUS" = "ok" ]; then
        update_usage_cache "$LABEL" "$UTIL" "$RESETS_AT" "ok" "start-all" "$SEVEN_DAY_UTIL" "$SEVEN_DAY_RESETS_AT"
    else
        update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "$STATUS" "start-all" "__KEEP__" "__KEEP__"
      log "SESSION: start-all skip $LABEL — usage status $STATUS"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    if [ "$RESETS_AT" = "none" ]; then
      log "SESSION: start-all skip $LABEL — no reset window"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    if [ "$(session_window_started "$LABEL" "$RESETS_AT")" = "yes" ]; then
      log "SESSION: start-all skip $LABEL — already started for window $RESETS_AT"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    restore_credentials "$LABEL"
    update_config "active_account" "\"$LABEL\""
    run_sync_session_for_label "$LABEL" "$UTIL" "$RESETS_AT" "start-all"
    STARTED_COUNT=$((STARTED_COUNT + 1))
  done < <(all_account_labels)
  log "SESSION: start-all finished — started=$STARTED_COUNT skipped=$SKIPPED_COUNT"
}

maybe_run_scheduled_session() {
  SCHEDULED_SESSION_STARTED="no"
  [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && return 0
  [ ! -x "$CLAUDE_BIN" ] && return 0
  claude_process_running && return 0

  local NEXT_LABEL NEXT_RESET_AT
  read -r NEXT_LABEL NEXT_RESET_AT <<< $(python3 -c "
import json, os
from datetime import datetime, timezone
from dateutil.parser import parse

path = '$SESSION_STATE'
if not os.path.exists(path):
    print('', '')
    raise SystemExit(0)

state = json.load(open(path))
scheduled = state.get('scheduled_resets', {})
last_windows = state.get('last_window_keys', {})
now = datetime.now(timezone.utc)
due = []
for label, reset_at in scheduled.items():
    if not reset_at or reset_at == 'none':
        continue
    try:
        if parse(reset_at) <= now and last_windows.get(label, '') != reset_at:
            due.append((parse(reset_at), label, reset_at))
    except Exception:
        continue
due.sort(key=lambda item: item[0])
if due:
    _, label, reset_at = due[0]
    print(label, reset_at)
else:
    print('', '')
" 2>/dev/null)

  [ -z "$NEXT_LABEL" ] && return 0

  if ! credentials_ready "$NEXT_LABEL"; then
    log "SESSION: skipping scheduled reset autostart for $NEXT_LABEL — credentials missing"
    return 0
  fi

  restore_credentials "$NEXT_LABEL"
  update_config "active_account" "\"$NEXT_LABEL\""
  start_background_session "$NEXT_LABEL" "$SESSION_AUTOSTART_THRESHOLD" "$NEXT_RESET_AT" "reset"
  SCHEDULED_SESSION_STARTED="yes"
}

maybe_autostart_session() {
  local LABEL="$1"
  local UTIL="$2"
  local RESETS_AT="$3"

  [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && return 0
  [ ! -x "$CLAUDE_BIN" ] && log "SESSION: skipped — claude CLI not found at $CLAUDE_BIN" && return 0
  claude_process_running && return 0

  local TODAY DAY_KEY WINDOW_KEY CURRENT_HOUR LAST_DAY_KEY LAST_WINDOW_KEY SHOULD_START REASON
  TODAY=$(date +%F)
  DAY_KEY="$TODAY"
  WINDOW_KEY="$RESETS_AT"
  CURRENT_HOUR=$(date +%H)
  SHOULD_START="no"
  REASON=""

  read -r LAST_DAY_KEY LAST_WINDOW_KEY <<< $(python3 -c "
import json, os
path = '$SESSION_STATE'
if os.path.exists(path):
    state = json.load(open(path))
    print(state.get('last_day_keys', {}).get('$LABEL', ''), state.get('last_window_keys', {}).get('$LABEL', ''))
else:
    print('', '')
" 2>/dev/null)

  if [ "$CURRENT_HOUR" -ge "$SESSION_AUTOSTART_HOUR" ] && [ "$LAST_DAY_KEY" != "$DAY_KEY" ]; then
    SHOULD_START="yes"
    REASON="daily"
  fi

  if [ "$UTIL" -ge "$SESSION_AUTOSTART_THRESHOLD" ] && [ "$RESETS_AT" != "none" ] && [ "$LAST_WINDOW_KEY" != "$WINDOW_KEY" ]; then
    SHOULD_START="yes"
    REASON=${REASON:+$REASON+threshold}
    REASON=${REASON:-threshold}
  fi

  [ "$SHOULD_START" != "yes" ] && return 0
  start_background_session "$LABEL" "$UTIL" "$WINDOW_KEY" "$REASON"
}

credentials_ready() {
  local LABEL="$1"
  [ -f "$(claude_json_backup "$LABEL")" ] && [ -f "$(keychain_backup "$LABEL")" ]
}

save_current_credentials() {
  local LABEL="$1"
  local REASON="${2:-save}"
  cp "$CLAUDE_JSON" "$(claude_json_backup "$LABEL")"
  if [ "$OS_TYPE" = "Darwin" ]; then
    security find-generic-password -l "$KEYCHAIN_SERVICE" -w 2>/dev/null | python3 -c "
import binascii, sys
raw = sys.stdin.buffer.read().strip()
payload = raw
if raw and not raw.startswith(b'{'):
    try:
        if all(byte in b'0123456789abcdefABCDEF' for byte in raw):
            decoded = binascii.unhexlify(raw)
            if decoded.lstrip().startswith(b'{'):
                payload = decoded
    except Exception:
        payload = raw
sys.stdout.buffer.write(payload)
" > "$(keychain_backup "$LABEL")"
  else
    # Linux: credentials live in ~/.claude/.credentials.json
    [ -f "$LINUX_CREDENTIALS" ] && cp "$LINUX_CREDENTIALS" "$(keychain_backup "$LABEL")"
  fi
  write_backup_metadata "$LABEL" "$REASON"
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
  if [ "$OS_TYPE" = "Darwin" ]; then
    local KEYCHAIN_DATA
    KEYCHAIN_DATA=$(python3 -c "
import binascii, sys
raw = open('$KEYCHAIN_FILE', 'rb').read().strip()
payload = raw
if raw.lstrip().startswith(b'{'):
    payload = binascii.hexlify(raw)
sys.stdout.write(payload.decode())
")
    security delete-generic-password -l "$KEYCHAIN_SERVICE" 2>/dev/null
    security add-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" \
      -l "$KEYCHAIN_SERVICE" -w "$KEYCHAIN_DATA" 2>/dev/null
  else
    # Linux: write directly to credentials file
    cp "$KEYCHAIN_FILE" "$LINUX_CREDENTIALS"
  fi
  [ -f "$SETTINGS_PERSONAL" ] && cp "$SETTINGS_PERSONAL" "$SETTINGS"
}

# ── Kitty terminal helpers ──
find_kitty_socket() {
  # Adjust the glob pattern to match your kitty socket name (set in kitty.conf)
  local SOCK
  SOCK=$(ls /tmp/kitty-* 2>/dev/null | head -1)
  [ -n "$SOCK" ] && echo "unix:$SOCK" || echo ""
}

find_all_kitty_sockets() {
  local SOCK
  for SOCK in /tmp/kitty-*; do
    [ ! -S "$SOCK" ] && continue
    echo "unix:$SOCK"
  done
}

kitty_send() {
  local MSG="$1"
  local SOCK
  SOCK=$(find_kitty_socket)
  [ -z "$SOCK" ] && log "KITTY: no socket found" && return 1
  "$KITTY_BIN" @ --to "$SOCK" send-text "${MSG}"$'\r' 2>/dev/null
}

kitty_send_to_socket() {
  local SOCK="$1"
  local MSG="$2"
  [ -z "$SOCK" ] && log "KITTY: no socket provided" && return 1
  "$KITTY_BIN" @ --to "$SOCK" send-text "${MSG}"$'\r' 2>/dev/null
}

resolve_continue_socket() {
  local EXPLICIT_SOCKET="$1"
  if [ -n "$EXPLICIT_SOCKET" ]; then
    echo "$EXPLICIT_SOCKET"
  elif [ -n "$KITTY_LISTEN_ON" ]; then
    echo "$KITTY_LISTEN_ON"
  else
    find_kitty_socket
  fi
}

  find_session_jsonl_path() {
    local SESSION_ID="$1"
    [ -z "$SESSION_ID" ] && return 1
    find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -n 1
  }

  last_used_model_for_session() {
    local SESSION_ID="$1"
    python3 -c "
  import json, os

  session_id = '$SESSION_ID'
  projects_root = os.path.expanduser('~/.claude/projects')
  target = ''
  for dirpath, _, filenames in os.walk(projects_root):
    candidate = f'{session_id}.jsonl'
    if candidate in filenames:
      target = os.path.join(dirpath, candidate)
      break

  if not target:
    print('')
    raise SystemExit(0)

  last_model = ''
  with open(target) as handle:
    for raw_line in handle:
      raw_line = raw_line.strip()
      if not raw_line:
        continue
      try:
        record = json.loads(raw_line)
      except Exception:
        continue
      message = record.get('message') or {}
      if isinstance(message, dict):
        model = message.get('model', '')
        if model:
          last_model = model

  print(last_model)
  " 2>/dev/null
  }

  list_active_claude_sessions() {
    python3 -c "
  import glob, json, os

  def process_alive(pid):
    try:
      os.kill(pid, 0)
      return True
    except OSError:
      return False

  def last_model(session_id):
    projects_root = os.path.expanduser('~/.claude/projects')
    target = ''
    for dirpath, _, filenames in os.walk(projects_root):
      candidate = f'{session_id}.jsonl'
      if candidate in filenames:
        target = os.path.join(dirpath, candidate)
        break
    if not target:
      return ''
    model = ''
    with open(target) as handle:
      for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
          continue
        try:
          record = json.loads(raw_line)
        except Exception:
          continue
        message = record.get('message') or {}
        if isinstance(message, dict):
          value = message.get('model', '')
          if value:
            model = value
    return model

  paths = sorted(glob.glob(os.path.expanduser('~/.claude/sessions/*.json')), key=os.path.getmtime, reverse=True)
  for path in paths:
    try:
      session = json.load(open(path))
    except Exception:
      continue
    pid = int(session.get('pid', 0) or 0)
    session_id = session.get('sessionId', '')
    cwd = session.get('cwd', '')
    started_at = str(session.get('startedAt', ''))
    name = session.get('name', '')
    if not pid or not session_id or not process_alive(pid):
      continue
    print('\t'.join([
      str(pid),
      session_id,
      cwd,
      last_model(session_id),
      started_at,
      name,
    ]))
  " 2>/dev/null
  }

  resolve_active_session_for_cwd() {
    local TARGET_CWD="$1"
    [ -z "$TARGET_CWD" ] && TARGET_CWD="$PWD"
    python3 -c "
  import glob, json, os

  target_cwd = '$TARGET_CWD'

  def process_alive(pid):
    try:
      os.kill(pid, 0)
      return True
    except OSError:
      return False

  def last_model(session_id):
    projects_root = os.path.expanduser('~/.claude/projects')
    target = ''
    for dirpath, _, filenames in os.walk(projects_root):
      candidate = f'{session_id}.jsonl'
      if candidate in filenames:
        target = os.path.join(dirpath, candidate)
        break
    if not target:
      return ''
    model = ''
    with open(target) as handle:
      for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
          continue
        try:
          record = json.loads(raw_line)
        except Exception:
          continue
        message = record.get('message') or {}
        if isinstance(message, dict):
          value = message.get('model', '')
          if value:
            model = value
    return model

  best = None
  paths = sorted(glob.glob(os.path.expanduser('~/.claude/sessions/*.json')), key=os.path.getmtime, reverse=True)
  for path in paths:
    try:
      session = json.load(open(path))
    except Exception:
      continue
    pid = int(session.get('pid', 0) or 0)
    session_id = session.get('sessionId', '')
    cwd = session.get('cwd', '')
    started_at = int(session.get('startedAt', 0) or 0)
    if not pid or not session_id or not cwd or not process_alive(pid):
      continue
    if cwd != target_cwd:
      continue
    row = [str(pid), session_id, cwd, last_model(session_id), str(started_at), session.get('name', '')]
    if best is None or started_at > best[4]:
      best = [row[0], row[1], row[2], row[3], started_at, row[5]]

  if best is not None:
    print('\t'.join([best[0], best[1], best[2], best[3], str(best[4]), best[5]]))
  " 2>/dev/null
  }

  resume_session_with_prompt() {
    local SESSION_ID="$1"
    local MODEL="$2"
    local SESSION_CWD="$3"
    local PROMPT="$4"

    [ -z "$SESSION_ID" ] && return 1
    [ -z "$MODEL" ] && return 1
    [ -z "$SESSION_CWD" ] && return 1
    [ -z "$PROMPT" ] && return 1

    (
    cd "$SESSION_CWD" 2>/dev/null || exit 1
    claude --resume "$SESSION_ID" --model "$MODEL" --dangerously-skip-permissions -p "$PROMPT" --output-format json --max-turns 1 >/dev/null 2>&1
    )
  }

known_reset_at_for_label() {
  local LABEL="$1"
  python3 -c "
import json, os

label = '$LABEL'
stats_path = '$CACHE'
usage_path = '$USAGE_CACHE'
state_path = '$SESSION_STATE'

def emit(value):
    if value and value != 'none':
        print(value)
        raise SystemExit(0)

if os.path.exists(stats_path):
    try:
        stats = json.load(open(stats_path))
        if stats.get('account', '') == label:
            emit((stats.get('usage', {}) or {}).get('five_hour', {}).get('resets_at', ''))
    except Exception:
        pass

if os.path.exists(usage_path):
    try:
        usage = json.load(open(usage_path))
        emit((usage.get('accounts', {}) or {}).get(label, {}).get('resets_at', ''))
    except Exception:
        pass

if os.path.exists(state_path):
    try:
        state = json.load(open(state_path))
        emit((state.get('sessions', {}) or {}).get(label, {}).get('reset_at', ''))
        emit((state.get('scheduled_resets', {}) or {}).get(label, ''))
    except Exception:
        pass

print('')
" 2>/dev/null
}

register_auto_continue() {
  local SESSION_NAME="$1"
  local LABEL="$2"
  local SESSION_ID="$3"
  local CONTINUE_TEXT="$4"
  local RESET_AT="$5"
  local NOW_S
  local SESSION_LINE
  local PID
  local SESSION_CWD
  local MODEL
  NOW_S=$(date +%s)

  [ -z "$SESSION_NAME" ] && SESSION_NAME="session-$NOW_S"
  [ -z "$LABEL" ] && LABEL=$(account_label "$(current_account_email)")
  [ -z "$CONTINUE_TEXT" ] && CONTINUE_TEXT="continue"
  [ -z "$RESET_AT" ] && RESET_AT=$(known_reset_at_for_label "$LABEL")

  if [ -n "$SESSION_ID" ]; then
    MODEL=$(last_used_model_for_session "$SESSION_ID")
    SESSION_CWD=$(python3 -c "
import json, glob, os
session_id = '$SESSION_ID'
for path in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
    try:
        data = json.load(open(path))
    except Exception:
        continue
    if data.get('sessionId', '') == session_id:
        print(data.get('cwd', ''))
        break
" 2>/dev/null)
  else
    SESSION_LINE=$(resolve_active_session_for_cwd "$PWD")
    IFS=$'\t' read -r PID SESSION_ID SESSION_CWD MODEL _ _ <<< "$SESSION_LINE"
  fi

  if [ -z "$LABEL" ] || [ "$LABEL" = "unknown" ]; then
    echo "error: could not determine account label" >&2
    return 1
  fi
  if [ -z "$SESSION_ID" ]; then
    echo "error: no active Claude session found for $PWD; pass a session id explicitly" >&2
    return 1
  fi
  if [ -z "$SESSION_CWD" ]; then
    echo "error: could not determine cwd for session $SESSION_ID" >&2
    return 1
  fi
  if [ -z "$MODEL" ]; then
    echo "error: could not determine last used model for session $SESSION_ID" >&2
    return 1
  fi
  if [ -z "$RESET_AT" ]; then
    echo "error: no reset time known for $LABEL yet" >&2
    return 1
  fi

  python3 -c "
import json, os, time

path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
auto = state.setdefault('auto_continue', {})
auto['$SESSION_NAME'] = {
    'session_name': '$SESSION_NAME',
    'label': '$LABEL',
  'session_id': '$SESSION_ID',
  'cwd': '$SESSION_CWD',
  'model': '$MODEL',
    'continue_text': '$CONTINUE_TEXT',
    'reset_at': '$RESET_AT',
    'registered_at': int(time.time()),
    'status': 'scheduled',
    'sent_at': 0,
    'last_error': ''
}
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null

  log "CONTINUE: registered $SESSION_NAME for $LABEL reset=$RESET_AT session=$SESSION_ID model=$MODEL"
  echo "registered $SESSION_NAME label=$LABEL reset=$RESET_AT session=$SESSION_ID model=$MODEL"
}

list_auto_continue() {
  python3 -c "
import json, os

path = '$SESSION_STATE'
if not os.path.exists(path):
    raise SystemExit(0)
state = json.load(open(path))
for name, entry in sorted((state.get('auto_continue', {}) or {}).items()):
    print('\t'.join([
        name,
        entry.get('label', ''),
        entry.get('status', ''),
        entry.get('reset_at', ''),
      entry.get('session_id', ''),
      entry.get('model', ''),
      entry.get('cwd', ''),
        entry.get('last_error', ''),
    ]))
" 2>/dev/null
}

clear_auto_continue() {
  local SESSION_NAME="$1"
  [ -z "$SESSION_NAME" ] && echo "error: session name required" >&2 && return 1
  python3 -c "
import json, os

path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
auto = state.setdefault('auto_continue', {})
auto.pop('$SESSION_NAME', None)
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
  log "CONTINUE: cleared $SESSION_NAME"
  echo "cleared $SESSION_NAME"
}

mark_auto_continue_result() {
  local SESSION_NAME="$1"
  local STATUS="$2"
  local ERROR_MSG="$3"
  python3 -c "
import json, os, time

path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
entry = (state.setdefault('auto_continue', {})).get('$SESSION_NAME', {})
if entry:
    entry['status'] = '$STATUS'
    entry['last_error'] = '$ERROR_MSG'
    entry['last_attempt_at'] = int(time.time())
    if '$STATUS' == 'sent':
        entry['sent_at'] = int(time.time())
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

maybe_run_auto_continue_sessions() {
  local DUE_LINES
  DUE_LINES=$(python3 -c "
import json, os
from datetime import datetime, timezone
from dateutil.parser import parse

path = '$SESSION_STATE'
if not os.path.exists(path):
    raise SystemExit(0)
state = json.load(open(path))
now = datetime.now(timezone.utc)
for name, entry in sorted((state.get('auto_continue', {}) or {}).items()):
    status = entry.get('status', 'scheduled')
    reset_at = entry.get('reset_at', '')
    if status == 'sent' or not reset_at:
        continue
    try:
        if parse(reset_at) <= now:
            print('\t'.join([
                name,
            entry.get('session_id', ''),
            entry.get('model', ''),
            entry.get('cwd', ''),
                entry.get('continue_text', 'continue'),
                entry.get('label', ''),
                reset_at,
            ]))
    except Exception:
        continue
" 2>/dev/null)

  [ -z "$DUE_LINES" ] && return 0

  while IFS=$'\t' read -r SESSION_NAME SESSION_ID MODEL SESSION_CWD CONTINUE_TEXT LABEL RESET_AT; do
    [ -z "$SESSION_NAME" ] && continue
    if resume_session_with_prompt "$SESSION_ID" "$MODEL" "$SESSION_CWD" "$CONTINUE_TEXT"; then
      mark_auto_continue_result "$SESSION_NAME" "sent" ""
      log "CONTINUE: sent '$CONTINUE_TEXT' to $SESSION_NAME for $LABEL via session $SESSION_ID model=$MODEL (reset=$RESET_AT)"
    else
      mark_auto_continue_result "$SESSION_NAME" "scheduled" "send_failed"
      log "CONTINUE: failed to send '$CONTINUE_TEXT' to $SESSION_NAME for $LABEL (session=$SESSION_ID model=$MODEL)"
    fi
  done <<< "$DUE_LINES"
}

pause_all_sessions_already_sent() {
  local LABEL="$1"
  local RESETS_AT="$2"
  python3 -c "
import json, os
path = '$SESSION_STATE'
if not os.path.exists(path):
    print('no')
    raise SystemExit(0)
state = json.load(open(path))
sent = state.get('pause_broadcasts', {})
print('yes' if sent.get('$LABEL', '') == '$RESETS_AT' else 'no')
" 2>/dev/null || echo "no"
}

mark_pause_all_sessions_sent() {
  local LABEL="$1"
  local RESETS_AT="$2"
  local COUNT="$3"
  python3 -c "
import json, os, time
path = '$SESSION_STATE'
state = {}
if os.path.exists(path):
    state = json.load(open(path))
sent = state.setdefault('pause_broadcasts', {})
sent['$LABEL'] = '$RESETS_AT'
state['last_pause_broadcast'] = {
    'label': '$LABEL',
    'reset_at': '$RESETS_AT',
    'session_count': int('$COUNT'),
    'sent_at': int(time.time())
}
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

broadcast_pause_to_all_sessions() {
  local MESSAGE="$1"
  local COUNT=0
  local PID
  local SESSION_ID
  local SESSION_CWD
  local MODEL
  local STARTED_AT
  local SESSION_NAME
  while IFS=$'\t' read -r PID SESSION_ID SESSION_CWD MODEL STARTED_AT SESSION_NAME; do
    [ -z "$SESSION_ID" ] && continue
    [ -z "$MODEL" ] && continue
    [ -z "$SESSION_CWD" ] && continue
    if resume_session_with_prompt "$SESSION_ID" "$MODEL" "$SESSION_CWD" "$MESSAGE"; then
      COUNT=$((COUNT + 1))
    fi
  done < <(list_active_claude_sessions)
  echo "$COUNT"
}

pause_all_sessions_for_full_capacity() {
  local LABEL="$1"
  local RESETS_AT="$2"
  local PAUSE_MESSAGE="pause until I say continue and pause again only when I say pause again"

  [ -z "$RESETS_AT" ] || [ "$RESETS_AT" = "none" ] || true

  if [ "$(pause_all_sessions_already_sent "$LABEL" "$RESETS_AT")" = "yes" ]; then
    log "PAUSE: already sent full-capacity pause for $LABEL window $RESETS_AT"
    return 0
  fi

  local SENT_COUNT
  SENT_COUNT=$(broadcast_pause_to_all_sessions "$PAUSE_MESSAGE")
  if [ "$SENT_COUNT" -gt 0 ] 2>/dev/null; then
    mark_pause_all_sessions_sent "$LABEL" "$RESETS_AT" "$SENT_COUNT"
    log "PAUSE: sent full-capacity pause to $SENT_COUNT Claude sessions for $LABEL window $RESETS_AT"
  else
    log "PAUSE: no active Claude sessions found for full-capacity pause on $LABEL window $RESETS_AT"
  fi
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
  local SESSION_ID="$3"
  local MODEL="$4"
  local SESSION_CWD="$5"
  kill_resume_timer
  (
    sleep "$WAIT_SECONDS"
    if [ -n "$SESSION_ID" ] && [ -n "$MODEL" ] && [ -n "$SESSION_CWD" ]; then
      if resume_session_with_prompt "$SESSION_ID" "$MODEL" "$SESSION_CWD" "continue"; then
        log "RESUME: sent 'continue' to session $SESSION_ID with model $MODEL (scheduled ${WAIT_SECONDS}s ago)"
      else
        kitty_send "continue"
        log "RESUME: session resume failed, sent 'continue' to kitty fallback"
      fi
    else
      kitty_send "continue"
      log "RESUME: sent 'continue' to kitty (scheduled ${WAIT_SECONDS}s ago)"
    fi
    osascript -e 'display notification "Continue sent to Kitty — session resuming" with title "Claude Auto-Switch"' 2>/dev/null
    rm -f "$RESUME_PID_FILE" "$HOME/.claude/auto-switch-resume-time.txt"
  ) &
  echo $! > "$RESUME_PID_FILE"
  [ -n "$RESUME_TIME" ] && echo "$RESUME_TIME" > "$HOME/.claude/auto-switch-resume-time.txt"
}

# ── Adaptive polling: reduce API calls when utilization is low ──
should_poll() {
  local LAST_UTIL LAST_POLL_TIME
  if claude_process_running; then
    echo "yes"
    return
  fi
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
  local CURRENT_LABEL
  CURRENT_LABEL=$(account_label "$(current_account_email)")
  if ! { [ "$OS_TYPE" = "Linux" ] && [ "$LABEL" = "$CURRENT_LABEL" ] && [ -f "$LINUX_CREDENTIALS" ]; }; then
    refresh_backup_token "$LABEL" >/dev/null 2>&1 || true
  fi
  get_token_raw "$LABEL"
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

case "$1" in
  register-auto-continue)
    register_auto_continue "$2" "$3" "$4" "$5" "$6"
    exit $?
    ;;
  list-active-sessions)
    list_active_claude_sessions
    exit 0
    ;;
  list-auto-continue)
    list_auto_continue
    exit 0
    ;;
  clear-auto-continue)
    clear_auto_continue "$2"
    exit $?
    ;;
  refresh-usage-cache)
    CUR_EMAIL=$(current_account_email)
    CUR_LABEL=$(account_label "$CUR_EMAIL")
    [ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"
    if [ -n "$CUR_LABEL" ] && [ "$CUR_LABEL" != "unknown" ]; then
      CUR_TOKEN=$(get_token "$CUR_LABEL")
      read -r CUR_STATUS CUR_UTIL CUR_RESETS_AT CUR_SEVEN_DAY_UTIL CUR_SEVEN_DAY_RESETS_AT <<< $(fetch_usage_detailed "$CUR_TOKEN")
      if [ "$CUR_STATUS" = "ok" ]; then
        update_usage_cache "$CUR_LABEL" "$CUR_UTIL" "$CUR_RESETS_AT" "ok" "live" "$CUR_SEVEN_DAY_UTIL" "$CUR_SEVEN_DAY_RESETS_AT"
      else
        update_usage_cache "$CUR_LABEL" "__KEEP__" "__KEEP__" "$CUR_STATUS" "live" "__KEEP__" "__KEEP__"
      fi
    fi
    refresh_next_usage_cache "$CUR_LABEL"
    exit 0
    ;;
  refresh-usage-cache-all)
    CUR_EMAIL=$(current_account_email)
    CUR_LABEL=$(account_label "$CUR_EMAIL")
    [ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"
    refresh_all_usage_cache
    exit 0
    ;;
  start-all-sessions)
    CUR_EMAIL=$(current_account_email)
    CUR_LABEL=$(account_label "$CUR_EMAIL")
    [ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"
    start_all_sessions
    exit 0
    ;;
esac

# Keep the active account's backup in sync with the real live credential before
# any refresh or polling. This preserves rotated refresh tokens after a manual
# re-login and prevents the timer from falling back to stale backups.
CUR_EMAIL=$(current_account_email)
CUR_LABEL=$(account_label "$CUR_EMAIL")
[ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"

# Keep backup tokens fresh on every timer run, independent of auto-switch state.
refresh_all_tokens
maybe_run_scheduled_session
[ "$SCHEDULED_SESSION_STARTED" = "yes" ] && exit 0
maybe_run_auto_continue_sessions

[ "$ENABLED" != "True" ] && [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && exit 0
[ "$(should_poll)" != "yes" ] && exit 0

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
  # Success — update cache + poll timer + refresh active account backup.
  python3 -c "
import json, time
now = int(time.time())
d = {'account': '$CUR_LABEL', 'usage': {'five_hour': {'utilization': $UTIL, 'resets_at': '$RESETS_AT' if '$RESETS_AT' != 'none' else None}}, 'timestamp': int(time.time() * 1000)}
json.dump(d, open('$CACHE', 'w'), indent=2)
json.dump({'util': $UTIL, 'time': now}, open('$LAST_POLL_FILE', 'w'))
" 2>/dev/null
  update_usage_cache "$CUR_LABEL" "$UTIL" "$RESETS_AT" "ok" "live" "__KEEP__" "__KEEP__"
  save_current_credentials "$CUR_LABEL"
fi

[ "$UTIL" -eq -1 ] 2>/dev/null && update_usage_cache "$CUR_LABEL" "__KEEP__" "__KEEP__" "api_error" "live" "__KEEP__" "__KEEP__"
refresh_next_usage_cache "$CUR_LABEL"

maybe_autostart_session "$CUR_LABEL" "$UTIL" "$RESETS_AT"
schedule_session_after_reset "$CUR_LABEL" "$UTIL" "$RESETS_AT"

log "POLL: $CUR_LABEL=${UTIL}%"

[ "$ENABLED" != "True" ] && exit 0

# Cooldown: no switch within 5 minutes of the last switch
NOW=$(date +%s)
ELAPSED=$((NOW - LAST_SWITCH_TIME))
[ "$ELAPSED" -lt 300 ] && exit 0

PREFERRED_TARGET=$(preferred_return_label "$CUR_LABEL" "$UTIL" "$PREFERRED_RETURN_THRESHOLD")
if [ -n "$PREFERRED_TARGET" ] && [ "$PREFERRED_TARGET" != "$CUR_LABEL" ]; then
  PREFERRED_TOKEN=$(get_token "$PREFERRED_TARGET")
  read -r PREFERRED_STATUS PREFERRED_UTIL PREFERRED_RESETS_AT PREFERRED_SEVEN_DAY_UTIL PREFERRED_SEVEN_DAY_RESETS_AT <<< $(fetch_usage_detailed "$PREFERRED_TOKEN")
  if [ "$PREFERRED_STATUS" = "ok" ]; then
    update_usage_cache "$PREFERRED_TARGET" "$PREFERRED_UTIL" "$PREFERRED_RESETS_AT" "ok" "priority-return" "$PREFERRED_SEVEN_DAY_UTIL" "$PREFERRED_SEVEN_DAY_RESETS_AT"
    if [ "$PREFERRED_UTIL" -lt "$PREFERRED_RETURN_THRESHOLD" ] 2>/dev/null; then
      perform_switch "$CUR_LABEL" "$UTIL" "$RESETS_AT" "$PREFERRED_TARGET" "$PREFERRED_UTIL" "$NOW" "priority-return"
      exit 0
    fi
  else
    update_usage_cache "$PREFERRED_TARGET" "__KEEP__" "__KEEP__" "$PREFERRED_STATUS" "priority-return" "__KEEP__" "__KEEP__"
  fi
fi

# ── Threshold check → Switch ──
if [ "$UTIL" -ge "$THRESHOLD" ]; then
  TARGET_INFO=$(find_ordered_switch_target "$CUR_LABEL" "$THRESHOLD")
  if [ -z "$TARGET_INFO" ]; then
    pause_all_sessions_for_full_capacity "$CUR_LABEL" "$RESETS_AT"
    log "SKIP: no account below threshold in configured order — current=$CUR_LABEL util=${UTIL}%"
    osascript -e "display notification \"All configured accounts are at or above ${THRESHOLD}%\" with title \"Claude Auto-Switch\"" 2>/dev/null
    exit 0
  fi

  IFS='|' read -r TARGET TARGET_UTIL TARGET_RESETS_AT <<< "$TARGET_INFO"
  perform_switch "$CUR_LABEL" "$UTIL" "$RESETS_AT" "$TARGET" "$TARGET_UTIL" "$NOW" "threshold"
fi
