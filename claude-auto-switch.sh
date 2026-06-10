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
TOKEN_SYNC_STATE="$HOME/.claude/token-sync-state.json"
TOKEN_SYNC_INTERVAL=120  # sync usage cache cross-machine every 2 minutes

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
  REMOTE_HOST=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('remote_host', ''))" 2>/dev/null)
  REFRESH_BACKUP_TOKENS=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('refresh_backup_tokens', True))" 2>/dev/null)
  SYNC_CREDENTIALS=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('sync_credentials', True))" 2>/dev/null)
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
if '$RESETS_AT' != '__KEEP__':
  entry['resets_at'] = '' if '$RESETS_AT' == 'none' else '$RESETS_AT'
if '$SEVEN_DAY_UTIL' != '__KEEP__':
  try:
    entry['seven_day_utilization'] = int(float('$SEVEN_DAY_UTIL'))
  except Exception:
    entry['seven_day_utilization'] = None
if '$SEVEN_DAY_RESETS_AT' != '__KEEP__':
  entry['seven_day_resets_at'] = '' if '$SEVEN_DAY_RESETS_AT' == 'none' else '$SEVEN_DAY_RESETS_AT'
entry['status'] = '$STATUS'
entry['source'] = '$SOURCE'
entry['checked_at'] = int(time.time() * 1000)
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

# Set/escalate the per-account 429 backoff (90s → 180s → 360s → 720s, cap 900s).
# All usage reads go through get_usage_for_label, which serves stale cache while
# backoff_until is in the future — so a throttled account is left alone to recover.
bump_usage_backoff() {
  local LABEL="$1"
  python3 -c "
import json, os, time
path = '$USAGE_CACHE'
state = json.load(open(path)) if os.path.exists(path) else {'accounts': {}}
entry = state.setdefault('accounts', {}).setdefault('$LABEL', {'label': '$LABEL'})
step = min(max(int(entry.get('backoff_s', 0)) * 2, 90), 900)
entry['backoff_s'] = step
entry['backoff_until'] = int(time.time()) + step
json.dump(state, open(path, 'w'), indent=2)
print(step)
" 2>/dev/null
}

clear_usage_backoff() {
  local LABEL="$1"
  python3 -c "
import json, os, time
path = '$USAGE_CACHE'
state = json.load(open(path)) if os.path.exists(path) else {'accounts': {}}
entry = state.setdefault('accounts', {}).setdefault('$LABEL', {'label': '$LABEL'})
entry.pop('backoff_s', None)
entry.pop('backoff_until', None)
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

# Cache-first usage lookup — THE single entry point for usage data.
# Echoes: STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT SOURCE
# Serves the cross-device-synced cache when fresh enough, respects per-account
# 429 backoff, and only then hits the usage API (updating cache + backoff state).
get_usage_for_label() {
  local LABEL="$1"
  local MAX_AGE="${2:-300}"
  local CACHED
  CACHED=$(python3 -c "
import json, os, time
path = '$USAGE_CACHE'
try:
    entry = json.load(open(path)).get('accounts', {}).get('$LABEL', {})
except Exception:
    entry = {}
def out(status, src):
    util = entry.get('utilization')
    seven = entry.get('seven_day_utilization')
    print(status,
          util if util is not None else 'none',
          entry.get('resets_at') or 'none',
          seven if seven is not None else 'none',
          entry.get('seven_day_resets_at') or 'none',
          src)
age_ms = time.time() * 1000 - entry.get('checked_at', 0)
if entry.get('status') == 'ok' and entry.get('utilization') is not None and age_ms < $MAX_AGE * 1000:
    out('ok', 'cache')
elif entry.get('backoff_until', 0) > time.time():
    out('rate_limited', 'backoff')
else:
    print('MISS')
" 2>/dev/null)
  if [ -n "$CACHED" ] && [ "$CACHED" != "MISS" ]; then
    echo "$CACHED"
    return 0
  fi
  local TOKEN STATUS UTIL RESETS_AT SEVEN SEVEN_AT
  TOKEN=$(get_token "$LABEL")
  read -r STATUS UTIL RESETS_AT SEVEN SEVEN_AT <<< $(fetch_usage_detailed "$TOKEN")
  if [ "$STATUS" = "ok" ]; then
    update_usage_cache "$LABEL" "$UTIL" "$RESETS_AT" "ok" "fetch" "$SEVEN" "$SEVEN_AT"
    clear_usage_backoff "$LABEL"
  elif [ "$STATUS" = "rate_limited" ]; then
    update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "rate_limited" "fetch" "__KEEP__" "__KEEP__"
    local STEP
    STEP=$(bump_usage_backoff "$LABEL")
    log "POLL: 429 for $LABEL — backing off ${STEP}s"
  else
    update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "$STATUS" "fetch" "__KEEP__" "__KEEP__"
  fi
  echo "$STATUS $UTIL $RESETS_AT $SEVEN $SEVEN_AT live"
}

# Read-only peek at the cached entry for a label (no API call ever).
# Echoes: STATUS UTIL RESETS_AT AGE_SECONDS
peek_cached_usage() {
  local LABEL="$1"
  python3 -c "
import json, os, time
path = '$USAGE_CACHE'
try:
    entry = json.load(open(path)).get('accounts', {}).get('$LABEL', {})
except Exception:
    entry = {}
util = entry.get('utilization')
age = int(time.time() - entry.get('checked_at', 0) / 1000) if entry.get('checked_at') else 999999
print(entry.get('status', 'none'), util if util is not None else 'none', entry.get('resets_at') or 'none', age)
" 2>/dev/null || echo "none none none 999999"
}

# Dead-account refresh gate: once a refresh token is confirmed invalid, retry at
# most once per hour instead of every 60s tick (kills log spam + extra API calls).
refresh_dead_until() {
  local LABEL="$1"
  python3 -c "
import json, os
path = '$USAGE_CACHE'
try:
    print(int(json.load(open(path)).get('accounts', {}).get('$LABEL', {}).get('refresh_dead_until', 0)))
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

set_refresh_dead_until() {
  local LABEL="$1"
  local SECONDS_AHEAD="${2:-3600}"
  python3 -c "
import json, os, time
path = '$USAGE_CACHE'
state = json.load(open(path)) if os.path.exists(path) else {'accounts': {}}
entry = state.setdefault('accounts', {}).setdefault('$LABEL', {'label': '$LABEL'})
entry['refresh_dead_until'] = int(time.time()) + $SECONDS_AHEAD
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

clear_refresh_dead() {
  local LABEL="$1"
  python3 -c "
import json, os
path = '$USAGE_CACHE'
if os.path.exists(path):
    state = json.load(open(path))
    entry = state.get('accounts', {}).get('$LABEL')
    if entry and entry.pop('refresh_dead_until', None) is not None:
        json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

# sha256[:16] of a backup's current refresh token (matches write_backup_metadata).
backup_refresh_hash() {
  local LABEL="$1"
  python3 -c "
import hashlib, json
try:
    rt = json.load(open('$(keychain_backup "$LABEL")')).get('claudeAiOauth', {}).get('refreshToken', '')
    print(hashlib.sha256(rt.encode()).hexdigest()[:16] if rt else '')
except Exception:
    print('')
" 2>/dev/null
}

# Mark/clear "this account's token chain was donated to the remote — log in again
# locally to get a fresh independent chain". Records the donated hash so a later
# local re-login (which changes the hash) auto-clears the flag — no manual save
# needed. Surfaced by SwiftBar so a donate is never silently forgotten.
set_needs_local_relogin() {
  local LABEL="$1"
  local DONATED_HASH
  DONATED_HASH=$(backup_refresh_hash "$LABEL")
  python3 -c "
import json, os, time
path = '$USAGE_CACHE'
state = json.load(open(path)) if os.path.exists(path) else {'accounts': {}}
entry = state.setdefault('accounts', {}).setdefault('$LABEL', {'label': '$LABEL'})
entry['needs_local_relogin'] = int(time.time())
entry['donated_refresh_hash'] = '$DONATED_HASH'
json.dump(state, open(path, 'w'), indent=2)
" 2>/dev/null
}

# Auto-clear needs_local_relogin once the local backup's refresh hash differs from
# the donated one — i.e. a fresh independent login has replaced the shared chain.
detect_local_relogin() {
  python3 -c "
import json, os
path = '$USAGE_CACHE'
if not os.path.exists(path):
    raise SystemExit(0)
for label, e in json.load(open(path)).get('accounts', {}).items():
    if isinstance(e, dict) and e.get('needs_local_relogin') and e.get('donated_refresh_hash'):
        print(label)
" 2>/dev/null | while IFS= read -r LBL; do
    [ -z "$LBL" ] && continue
    local CUR_HASH DONATED
    CUR_HASH=$(backup_refresh_hash "$LBL")
    DONATED=$(python3 -c "import json; print(json.load(open('$USAGE_CACHE'))['accounts'].get('$LBL',{}).get('donated_refresh_hash',''))" 2>/dev/null)
    if [ -n "$CUR_HASH" ] && [ "$CUR_HASH" != "$DONATED" ]; then
      clear_needs_local_relogin "$LBL"
      clear_refresh_dead "$LBL"
      python3 -c "
import json
s=json.load(open('$USAGE_CACHE')); e=s['accounts'].get('$LBL',{})
e.pop('donated_refresh_hash', None); json.dump(s,open('$USAGE_CACHE','w'),indent=2)
" 2>/dev/null
      log "REPAIR: detected fresh local login for $LBL — cleared re-login reminder"
    fi
  done
}

clear_needs_local_relogin() {
  local LABEL="$1"
  python3 -c "
import json, os
path = '$USAGE_CACHE'
if os.path.exists(path):
    state = json.load(open(path))
    entry = state.get('accounts', {}).get('$LABEL')
    if entry and entry.pop('needs_local_relogin', None) is not None:
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
    # Cache-first (10 min tolerance): candidate ranking doesn't need second-fresh
    # data, and polling every candidate on each switch attempt burns the per-account
    # usage-API rate budget.
    local STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE
    read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE <<< $(get_usage_for_label "$LABEL" 600)
    if [ "$STATUS" = "ok" ]; then
      if [ "$UTIL" -lt "$LIMIT" ] 2>/dev/null; then
        echo "$LABEL|$UTIL|$RESETS_AT"
        return 0
      fi
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

  # Record when we switched away from the current account (ping-pong guard)
  python3 -c "
import json, os, time
p = os.path.expanduser('~/.claude/auto-switch-history.json')
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault('switched_away', {})['$CURRENT_LABEL'] = int(time.time())
json.dump(d, open(p, 'w'), indent=2)
" 2>/dev/null

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

# Refresh all backup tokens that are expiring soon.
# Only runs if refresh_backup_tokens is True (default).
# Set to False on secondary machines that receive tokens via cross-machine sync.
refresh_all_tokens() {
  if [ "$REFRESH_BACKUP_TOKENS" = "False" ]; then
    return 0
  fi
  local CURRENT_LABEL
  CURRENT_LABEL=$(account_label "$(current_account_email)")
  local CLAUDE_RUNNING="no"
  claude_process_running && CLAUDE_RUNNING="yes"
  for f in "$HOME"/.claude-keychain-*.json; do
    [ ! -f "$f" ] && continue
    local LABEL
    LABEL=$(echo "$f" | sed "s|.*\.claude-keychain-\(.*\)\.json|\1|")
    # Never rotate the active account's token while Claude Code owns it (would
    # consume the live refresh token and force a re-login on the next launch).
    if [ "$LABEL" = "$CURRENT_LABEL" ] && [ "$CLAUDE_RUNNING" = "yes" ]; then
      continue
    fi
    # Dead refresh token: don't hammer the token endpoint every tick — retry hourly.
    if [ "$(refresh_dead_until "$LABEL")" -gt "$(date +%s)" ]; then
      continue
    fi
    local RESULT
    RESULT=$(refresh_backup_token "$LABEL" 2>&1)
    if [ -n "$RESULT" ]; then
      log "TOKEN: $LABEL: $RESULT"
      audit_refresh_event "$LABEL" "$RESULT"
      case "$RESULT" in
        *"Refresh token not found or invalid"*|*"reason=no_refresh_token"*)
          set_refresh_dead_until "$LABEL" 3600
          if [ "$LABEL" != "$CURRENT_LABEL" ]; then
            # Refresh token is dead, but the access token may still be valid for a
            # while — check (cache-first) so the status display stays accurate.
            local STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE
            read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE <<< $(get_usage_for_label "$LABEL" 600)
            if [ "$STATUS" != "ok" ] && [ "$STATUS" != "rate_limited" ]; then
              update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "unauthorized" "refresh-audit"
            fi
          fi
          ;;
        REFRESHED*)
          clear_refresh_dead "$LABEL"
          # Active account refreshed while Claude is closed: mirror the new token
          # into the live store so the next Claude/PAI launch never sees a stale,
          # already-consumed refresh token (= no more login prompts).
          if [ "$LABEL" = "$CURRENT_LABEL" ]; then
            if write_live_credentials_from_backup "$LABEL"; then
              log "TOKEN: $LABEL: wrote refreshed token to live store"
            else
              log "WARN: $LABEL: failed to write refreshed token to live store"
            fi
          fi
          ;;
      esac
      case "$RESULT" in
        REFRESHED*|SKIP_REFRESH*) write_backup_metadata "$LABEL" "refresh" ;;
      esac
      # If token was rotated, immediately push to remote to prevent the other machine
      # from trying to use the now-dead old token.
      case "$RESULT" in
        *rotated=yes*)
          if [ -n "$REMOTE_HOST" ]; then
            scp -o ConnectTimeout=5 "$HOME/.claude-keychain-$LABEL.json" "$REMOTE_HOST":~/.claude-keychain-"$LABEL".json 2>/dev/null && \
            { [ ! -f "$HOME/.claude.json.$LABEL" ] || scp -o ConnectTimeout=5 "$HOME/.claude.json.$LABEL" "$REMOTE_HOST":~/.claude.json."$LABEL" 2>/dev/null; } && \
            { [ ! -f "$HOME/.claude-meta-$LABEL.json" ] || scp -o ConnectTimeout=5 "$HOME/.claude-meta-$LABEL.json" "$REMOTE_HOST":~/.claude-meta-"$LABEL".json 2>/dev/null; } && \
            log "SYNC: pushed rotated token bundle for $LABEL to $REMOTE_HOST"
          fi
          ;;
      esac
    fi
  done
}

# ── Cross-machine token sync ──
# Compares local and remote backup token freshness (by expiresAt).
# Pulls fresher tokens from remote, pushes fresher local tokens to remote.
# Skips the currently active account (don't overwrite live credentials).
# Rate-limited to run every TOKEN_SYNC_INTERVAL seconds.
sync_tokens_cross_machine() {
  [ -z "$REMOTE_HOST" ] && return 0

  # Rate limit: only sync every TOKEN_SYNC_INTERVAL seconds
  local LAST_SYNC NOW ELAPSED
  NOW=$(date +%s)
  LAST_SYNC=$(python3 -c "
import json, os
f = '$TOKEN_SYNC_STATE'
print(json.load(open(f)).get('last_sync', 0) if os.path.exists(f) else 0)
" 2>/dev/null || echo "0")
  ELAPSED=$((NOW - LAST_SYNC))
  [ "$ELAPSED" -lt "$TOKEN_SYNC_INTERVAL" ] && return 0

  # Check SSH connectivity (fast timeout)
  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$REMOTE_HOST" true 2>/dev/null; then
    log "SYNC: remote $REMOTE_HOST unreachable — skipping"
    # Still update timestamp to avoid retrying every second
    python3 -c "import json, time; json.dump({'last_sync': int(time.time())}, open('$TOKEN_SYNC_STATE', 'w'))" 2>/dev/null
    return 0
  fi

  # Independent mode: only sync the usage cache, not credential files.
  # This avoids OAuth token-rotation race conditions when each device manages
  # its own refresh chain independently.
  if [ "$SYNC_CREDENTIALS" = "False" ]; then
    local REMOTE_CACHE="/tmp/claude-usage-cache-remote.json"
    local REMOTE_POLL="/tmp/claude-last-poll-remote.json"
    # Pull remote usage cache + poll state in parallel
    scp -o ConnectTimeout=5 \
        "$REMOTE_HOST":"$HOME/.claude/account-usage-cache.json" "$REMOTE_CACHE" \
        2>/dev/null &
    scp -o ConnectTimeout=5 \
        "$REMOTE_HOST":"$HOME/.claude/auto-switch-last-poll.json" "$REMOTE_POLL" \
        2>/dev/null &
    wait
    # Merge usage cache: keep per-account entry with the newer timestamp
    python3 -c "
import json, os
local_f = os.path.expanduser('~/.claude/account-usage-cache.json')
remote_f = '$REMOTE_CACHE'
if not os.path.exists(remote_f):
    exit()
local_d = json.load(open(local_f)) if os.path.exists(local_f) else {'accounts': {}}
remote_d = json.load(open(remote_f))
local_accts = local_d.get('accounts', {}) if isinstance(local_d, dict) else {}
remote_accts = remote_d.get('accounts', {}) if isinstance(remote_d, dict) else {}
merged = dict(local_accts)
for k, rv in remote_accts.items():
    # Entries are stamped with checked_at (ms) by update_usage_cache —
    # the newer reading wins, regardless of which device produced it.
    rt = rv.get('checked_at', 0)
    lt = local_accts.get(k, {}).get('checked_at', 0)
    if rt > lt:
        merged[k] = rv
out = dict(local_d) if isinstance(local_d, dict) else {}
out['accounts'] = merged
json.dump(out, open(local_f, 'w'), indent=2)
" 2>/dev/null
    # Merge poll state: keep the most recent poll time so both devices share one rate-limit budget
    python3 -c "
import json, os
local_f = os.path.expanduser('~/.claude/auto-switch-last-poll.json')
remote_f = '$REMOTE_POLL'
if not os.path.exists(remote_f):
    exit()
local_d = json.load(open(local_f)) if os.path.exists(local_f) else {}
remote_d = json.load(open(remote_f))
# Take the more recent poll time
lt = local_d.get('time', 0)
rt = remote_d.get('time', 0)
if rt > lt:
    # Remote polled more recently — adopt its timestamp so we wait out the remainder
    merged = dict(local_d)
    merged['time'] = rt
    # Propagate throttle backoff from remote if more recent
    if remote_d.get('throttled_at', 0) > local_d.get('throttled_at', 0):
        merged['throttled_at'] = remote_d['throttled_at']
    json.dump(merged, open(local_f, 'w'), indent=2)
" 2>/dev/null
    # Push merged files back to remote
    scp -o ConnectTimeout=5 "$HOME/.claude/account-usage-cache.json" \
        "$REMOTE_HOST":"$HOME/.claude/account-usage-cache.json" 2>/dev/null &
    scp -o ConnectTimeout=5 "$HOME/.claude/auto-switch-last-poll.json" \
        "$REMOTE_HOST":"$HOME/.claude/auto-switch-last-poll.json" 2>/dev/null &
    wait
    rm -f "$REMOTE_CACHE" "$REMOTE_POLL"
    # Fetch remote's active account + hostname for status display (SwiftBar remote section)
    local REMOTE_STATUS
    REMOTE_STATUS=$(ssh -o ConnectTimeout=3 "$REMOTE_HOST" "python3 -c \"
import json, os, socket
p = os.path.expanduser('~/.claude/auto-switch-config.json')
cfg = json.load(open(p)) if os.path.exists(p) else {}
print(json.dumps({'active_account': cfg.get('active_account',''), 'hostname': socket.gethostname()}))
\"" 2>/dev/null)
    [ -n "$REMOTE_STATUS" ] && echo "$REMOTE_STATUS" > "$HOME/.claude/remote-status.json"
    # Pull a filtered tail of the remote log so SwiftBar can show Ubuntu activity
    # offline (no SSH on every menu render). Cheap: one grep|tail over SSH per sync.
    ssh -o ConnectTimeout=3 "$REMOTE_HOST" \
      "grep -E 'SWITCH|POLL|throttled|cache-threshold|LIMIT: triggered|SESSION: opened' ~/.claude/auto-switch.log | tail -n 30" \
      2>/dev/null > "$HOME/.claude/ubuntu-recent-log.txt"
    log "SYNC: usage-only sync with $REMOTE_HOST (sync_credentials=false)"
    python3 -c "import json, time; json.dump({'last_sync': int(time.time())}, open('$TOKEN_SYNC_STATE', 'w'))" 2>/dev/null
    return 0
  fi

  # Single Python script: gather local data, SSH for remote, compare, output actions
  local ACTIONS_FILE="/tmp/claude-token-sync-actions.txt"
  local CURRENT_LABEL
  CURRENT_LABEL=$(account_label "$(current_account_email)")

  # Gather remote expiresAt via SSH
  local REMOTE_FILE="/tmp/claude-token-sync-remote.json"
  ssh -o ConnectTimeout=5 "$REMOTE_HOST" "python3 -c \"
import json, glob, os
result = {}
for f in glob.glob(os.path.expanduser('~/.claude-keychain-*.json')):
    label = f.split('.claude-keychain-')[1].replace('.json', '')
    try:
        cred = json.load(open(f))
        result[label] = cred.get('claudeAiOauth', {}).get('expiresAt', 0)
    except: pass
print(json.dumps(result))
\"" 2>/dev/null > "$REMOTE_FILE"

  [ ! -s "$REMOTE_FILE" ] && return 0

  # Compare local vs remote and write action list
  python3 -c "
import json, glob, os

remote = json.load(open('$REMOTE_FILE'))
current_label = '$CURRENT_LABEL'
actions = []

local_data = {}
for f in glob.glob(os.path.expanduser('~/.claude-keychain-*.json')):
    label = f.split('.claude-keychain-')[1].replace('.json', '')
    try:
        cred = json.load(open(f))
        local_data[label] = cred.get('claudeAiOauth', {}).get('expiresAt', 0)
    except:
        pass

all_labels = set(list(local_data.keys()) + list(remote.keys()))
for label in sorted(all_labels):
    l_exp = local_data.get(label, 0)
    r_exp = remote.get(label, 0)
    if r_exp > l_exp and r_exp > 0:
        actions.append(f'PULL {label}')
    elif l_exp > r_exp and l_exp > 0:
        actions.append(f'PUSH {label}')

with open('$ACTIONS_FILE', 'w') as f:
    f.write('\n'.join(actions))
" 2>/dev/null

  [ ! -s "$ACTIONS_FILE" ] && {
    python3 -c "import json, time; json.dump({'last_sync': int(time.time())}, open('$TOKEN_SYNC_STATE', 'w'))" 2>/dev/null
    rm -f "$REMOTE_FILE" "$ACTIONS_FILE"
    return 0
  }

  while IFS=' ' read -r ACTION LABEL; do
    [ -z "$ACTION" ] || [ -z "$LABEL" ] && continue
    # Skip the currently active account — don't overwrite live credentials
    if [ "$LABEL" = "$CURRENT_LABEL" ]; then
      log "SYNC: skipping $LABEL (currently active)"
      continue
    fi
    if [ "$ACTION" = "PULL" ]; then
      scp -o ConnectTimeout=5 "$REMOTE_HOST":~/.claude-keychain-"$LABEL".json "$HOME/.claude-keychain-$LABEL.json" 2>/dev/null && \
      scp -o ConnectTimeout=5 "$REMOTE_HOST":~/.claude.json."$LABEL" "$HOME/.claude.json.$LABEL" 2>/dev/null && \
      scp -o ConnectTimeout=5 "$REMOTE_HOST":~/.claude-meta-"$LABEL".json "$HOME/.claude-meta-$LABEL.json" 2>/dev/null
      log "SYNC: pulled fresher token for $LABEL from $REMOTE_HOST"
    elif [ "$ACTION" = "PUSH" ]; then
      scp -o ConnectTimeout=5 "$HOME/.claude-keychain-$LABEL.json" "$REMOTE_HOST":~/.claude-keychain-"$LABEL".json 2>/dev/null && \
      scp -o ConnectTimeout=5 "$HOME/.claude.json.$LABEL" "$REMOTE_HOST":~/.claude.json."$LABEL" 2>/dev/null && \
      scp -o ConnectTimeout=5 "$HOME/.claude-meta-$LABEL.json" "$REMOTE_HOST":~/.claude-meta-"$LABEL".json 2>/dev/null
      log "SYNC: pushed fresher token for $LABEL to $REMOTE_HOST"
    fi
  done < "$ACTIONS_FILE"

  rm -f "$REMOTE_FILE" "$ACTIONS_FILE"

  # Update last sync time
  python3 -c "import json, time; json.dump({'last_sync': int(time.time())}, open('$TOKEN_SYNC_STATE', 'w'))" 2>/dev/null
}

get_token_raw() {
  local LABEL="$1"
  local CURRENT_LABEL
  CURRENT_LABEL=$(account_label "$(current_account_email)")
  python3 -c "
import json, binascii, os
label = '$LABEL'
current_label = '$CURRENT_LABEL'
live_file = '$LINUX_CREDENTIALS'
backup_file = '$(keychain_backup "$LABEL")'
f = live_file if '$OS_TYPE' == 'Linux' and label == current_label and os.path.exists(live_file) else backup_file
raw = open(f, 'rb').read().strip()
# Self-heal: a backup written as keychain hex (a known bug in some save paths)
# is transparently decoded here AND rewritten as JSON so it never bites again.
if raw and not raw.lstrip().startswith(b'{'):
    try:
        if all(c in b'0123456789abcdefABCDEF' for c in raw):
            dec = binascii.unhexlify(raw)
            if dec.lstrip().startswith(b'{'):
                raw = dec
                if f == backup_file:
                    open(f, 'w').write(dec.decode())
    except Exception:
        pass
print(json.loads(raw).get('claudeAiOauth', {}).get('accessToken', ''))
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

# Real 5h utilization from the Messages API response headers
# (anthropic-ratelimit-unified-5h-*). This is a SEPARATE endpoint from
# /oauth/usage, so it is NOT subject to the aggressive usage-poll throttle that
# Claude Code's own polling triggers — it returns the true number even when
# /oauth/usage 429s. Echoes: STATUS UTIL RESETS_AT  (status=ok always when a
# utilization header is present, regardless of HTTP 200 vs 429; util can exceed
# 100 when over the cap). Costs one 1-token Messages call.
fetch_usage_via_messages() {
  local TOKEN="$1"
  [ -z "$TOKEN" ] && echo "missing_token none none" && return
  python3 -c "
import json, urllib.request, urllib.error
from datetime import datetime, timezone
token = '$TOKEN'
body = json.dumps({'model':'claude-haiku-4-5-20251001','max_tokens':1,'messages':[{'role':'user','content':'hi'}]}).encode()
req = urllib.request.Request('https://api.anthropic.com/v1/messages', data=body, headers={
    'Authorization': f'Bearer {token}', 'Content-Type':'application/json',
    'anthropic-version':'2023-06-01', 'anthropic-beta':'oauth-2025-04-20'})

def parse(headers):
    h = {k.lower(): v for k, v in headers.items()}
    util = h.get('anthropic-ratelimit-unified-5h-utilization')
    reset = h.get('anthropic-ratelimit-unified-5h-reset')
    if util is None:
        return None
    pct = int(round(float(util) * 100)) if float(util) <= 2 else int(float(util))
    iso = 'none'
    if reset:
        try: iso = datetime.fromtimestamp(int(reset), tz=timezone.utc).isoformat()
        except ValueError: iso = 'none'
    return f'ok {pct} {iso}'

try:
    with urllib.request.urlopen(req, timeout=15) as r:
        out = parse(r.headers)
        print(out if out else 'missing_window none none')
except urllib.error.HTTPError as e:
    out = parse(e.headers)              # 429 still carries the real util header
    if out:
        print(out)
    elif e.code == 401:
        print('unauthorized none none')
    else:
        print(f'http_{e.code} none none')
except Exception:
    print('request_failed none none')
" 2>/dev/null || echo "request_failed none none"
}

claude_session_active() {
  # Returns true if any conversation JSONL was written in the last 2 minutes.
  # More accurate than pgrep: idle Claude open on the desktop does not count.
  python3 -c "
import os, time, sys
cutoff = time.time() - 120
projects = os.path.expanduser('~/.claude/projects')
for root, dirs, files in os.walk(projects):
    for f in files:
        if f.endswith('.jsonl'):
            try:
                if os.path.getmtime(os.path.join(root, f)) > cutoff:
                    sys.exit(0)
            except OSError:
                pass
sys.exit(1)
" 2>/dev/null
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
  local FORCE="${4:-no}"

  [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && [ "$FORCE" != "yes" ] && return 0
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

  # Open the 5h window via direct API (no keychain swap, no active-session disruption)
  trigger_limit_for_label "$LABEL"
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
  mark_session_started "$LABEL" "$RESETS_AT" "$REASON" ""
  log "SESSION: opened 5h window for $LABEL ($REASON, util=${UTIL}%)"
}

run_sync_session_for_label() {
  local LABEL="$1"
  local UTIL="$2"
  local RESETS_AT="$3"
  local REASON="$4"
  # Open the 5h window via direct API (no keychain swap, no active-session disruption)
  trigger_limit_for_label "$LABEL"
  mark_session_autostart "$LABEL" "$(date +%F)" "$RESETS_AT"
  mark_session_started "$LABEL" "$RESETS_AT" "$REASON" ""
  log "SESSION: opened 5h window for $LABEL ($REASON, util=${UTIL}%)"
}

# Trigger the 5h usage limit window for a label via a direct Messages API call.
# Uses the account's backup OAuth token — does NOT swap the live keychain or run
# the claude CLI, so it never disrupts the currently active Claude Code session.
trigger_limit_for_label() {
  local LABEL="$1"
  if ! credentials_ready "$LABEL"; then
    log "LIMIT: trigger skip $LABEL — credentials not ready"
    return 1
  fi
  # Ensure token is fresh before the API call
  local REFRESH_RESULT
  REFRESH_RESULT=$(refresh_backup_token "$LABEL" 2>/dev/null)
  log "LIMIT: refresh before trigger $LABEL: $REFRESH_RESULT"

  local TOKEN
  TOKEN=$(get_token_raw "$LABEL")
  if [ -z "$TOKEN" ]; then
    log "LIMIT: trigger FAILED for $LABEL — no token available"
    return 1
  fi

  # Minimal Messages API request: opens a fresh 5h window for this account.
  # Bonus: Messages responses carry anthropic-ratelimit-unified-* headers with
  # the 5h utilization — usage data with ZERO usage-endpoint calls. Harvest it.
  local RESULT
  RESULT=$(python3 -c "
import urllib.request, urllib.error, json
body = json.dumps({
  'model': 'claude-haiku-4-5-20251001',
  'max_tokens': 1,
  'messages': [{'role': 'user', 'content': 'hi'}]
}).encode()
req = urllib.request.Request(
  'https://api.anthropic.com/v1/messages',
  data=body,
  headers={
    'Authorization': 'Bearer $TOKEN',
    'Content-Type': 'application/json',
    'anthropic-version': '2023-06-01',
    'anthropic-beta': 'oauth-2025-04-20'
  }
)
def ratelimit_headers(headers):
  pairs = [f'{k.lower()}={v}' for k, v in headers.items() if k.lower().startswith('anthropic-ratelimit')]
  return ';'.join(pairs)
try:
  with urllib.request.urlopen(req, timeout=15) as r:
    json.loads(r.read())
    print('ok|' + ratelimit_headers(r.headers))
except urllib.error.HTTPError as e:
  # 429 = already rate-limited (window is open, that's fine). Others = real error.
  if e.code == 429:
    print('ok|' + ratelimit_headers(e.headers))
  else:
    print(f'http_{e.code}|')
except Exception as ex:
  print(f'error_{type(ex).__name__}|')
" 2>/dev/null)

  local STATUS_PART HEADERS_PART
  STATUS_PART="${RESULT%%|*}"
  HEADERS_PART="${RESULT#*|}"
  if [ -n "$HEADERS_PART" ]; then
    log "LIMIT: ratelimit headers for $LABEL: $HEADERS_PART"
    # If the unified headers expose 5h utilization/reset, feed the usage cache.
    python3 -c "
import time
from datetime import datetime, timezone
headers = dict(p.split('=', 1) for p in '$HEADERS_PART'.split(';') if '=' in p)
util = None
reset = ''
for k, v in headers.items():
    if 'utilization' in k and '5h' in k:
        try: util = int(float(v) * 100) if float(v) <= 1 else int(float(v))
        except ValueError: pass
    if k.endswith('5h-reset'):
        # Header carries epoch seconds; the cache stores ISO 8601
        try: reset = datetime.fromtimestamp(int(v), tz=timezone.utc).isoformat()
        except ValueError: reset = ''
if util is not None:
    print(f'{util}|{reset}')
" 2>/dev/null | while IFS='|' read -r H_UTIL H_RESET; do
      [ -n "$H_UTIL" ] && update_usage_cache "$LABEL" "$H_UTIL" "${H_RESET:-__KEEP__}" "ok" "messages-headers" "__KEEP__" "__KEEP__"
    done
  fi

  if [ "$STATUS_PART" = "ok" ]; then
    log "LIMIT: triggered 5h window for $LABEL (direct API)"
    return 0
  else
    log "LIMIT: trigger FAILED for $LABEL — $STATUS_PART"
    return 1
  fi
}

refresh_next_usage_cache() {
  local CURRENT_LABEL="$1"
  local NEXT_LABEL
  NEXT_LABEL=$(next_usage_refresh_label "$CURRENT_LABEL")
  [ -z "$NEXT_LABEL" ] && return 0
  # Cache-first round-robin: skips the API entirely when the other device
  # already refreshed this account in the last 10 minutes.
  get_usage_for_label "$NEXT_LABEL" 600 >/dev/null
}

refresh_all_usage_cache() {
  while IFS= read -r LABEL; do
    [ -z "$LABEL" ] && continue
    if ! credentials_ready "$LABEL"; then
      update_usage_cache "$LABEL" "__KEEP__" "__KEEP__" "missing_credentials" "full-refresh"
      continue
    fi
    # 30s tolerance: manual refresh still pulls fresh data, but respects the
    # per-account 429 backoff and doesn't double-hit just-polled accounts.
    get_usage_for_label "$LABEL" 30 >/dev/null
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
    local STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE
    read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE <<< $(get_usage_for_label "$LABEL" 300)
    if [ "$STATUS" != "ok" ]; then
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
    run_sync_session_for_label "$LABEL" "$UTIL" "$RESETS_AT" "start-all"
    STARTED_COUNT=$((STARTED_COUNT + 1))
  done < <(all_account_labels)
  log "SESSION: start-all finished — started=$STARTED_COUNT skipped=$SKIPPED_COUNT"
}

restart_all_sessions() {
  # Open 5h usage windows for all accounts via direct Messages API calls using
  # each account's backup token. Never swaps the live keychain, so the active
  # Claude Code session is never disrupted. Accounts still over threshold are
  # scheduled to open after their reset.
  local TRIGGERED_COUNT=0
  local SCHEDULED_COUNT=0
  local SKIPPED_COUNT=0

  while IFS= read -r LABEL; do
    [ -z "$LABEL" ] && continue
    if ! credentials_ready "$LABEL"; then
      log "LIMIT: restart-all skip $LABEL — credentials missing"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    local STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE
    read -r STATUS UTIL RESETS_AT SEVEN_DAY_UTIL SEVEN_DAY_RESETS_AT USAGE_SOURCE <<< $(get_usage_for_label "$LABEL" 300)
    if [ "$STATUS" != "ok" ]; then
      log "LIMIT: restart-all skip $LABEL — usage status $STATUS"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi

    if [ "$UTIL" -lt "$SESSION_AUTOSTART_THRESHOLD" ] 2>/dev/null; then
      # Limit has reset or is low — trigger NOW
      if [ "$(session_window_started "$LABEL" "$RESETS_AT")" = "yes" ] && [ "$RESETS_AT" != "none" ]; then
        log "LIMIT: restart-all skip $LABEL — already triggered for window $RESETS_AT"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
      fi
      if trigger_limit_for_label "$LABEL"; then
        mark_session_autostart "$LABEL" "$(date +%F)" "$RESETS_AT"
        mark_session_started "$LABEL" "$RESETS_AT" "restart-all" ""
        TRIGGERED_COUNT=$((TRIGGERED_COUNT + 1))
      else
        log "LIMIT: restart-all trigger failed for $LABEL"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      fi
    elif [ "$RESETS_AT" != "none" ]; then
      # Limit still active — schedule for after reset
      schedule_session_after_reset "$LABEL" "$UTIL" "$RESETS_AT" "yes"
      log "LIMIT: restart-all scheduled $LABEL for after reset at $RESETS_AT (util=${UTIL}%)"
      SCHEDULED_COUNT=$((SCHEDULED_COUNT + 1))
    else
      log "LIMIT: restart-all skip $LABEL — no reset window, util=${UTIL}%"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
  done < <(all_account_labels)

  log "LIMIT: restart-all finished — triggered=$TRIGGERED_COUNT scheduled=$SCHEDULED_COUNT skipped=$SKIPPED_COUNT"
  echo "triggered=$TRIGGERED_COUNT scheduled=$SCHEDULED_COUNT skipped=$SKIPPED_COUNT"
}

maybe_run_scheduled_session() {
  SCHEDULED_SESSION_STARTED="no"
  [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && return 0
  # NOTE: no claude_process_running / CLAUDE_BIN guard. Opening a window is a
  # direct Messages API call (trigger_limit_for_label) that never touches the
  # live login, so it's safe to fire even while a Claude Code session is active.
  # The old guards meant scheduled after-reset triggers never fired on a machine
  # that always has Claude running (e.g. the Ubuntu agent host).

  # All accounts whose reset time has passed and haven't been opened for that
  # window yet. Reset times are 10-min-rounded and tend to cluster, so fire them
  # all in this tick rather than one-per-minute.
  local DUE_LABELS
  DUE_LABELS=$(python3 -c "
import json, os
from datetime import datetime, timezone
from dateutil.parser import parse

path = '$SESSION_STATE'
if not os.path.exists(path):
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
for _, label, reset_at in due:
    print(f'{label}\t{reset_at}')
" 2>/dev/null)

  [ -z "$DUE_LABELS" ] && return 0

  while IFS=$'\t' read -r NEXT_LABEL NEXT_RESET_AT; do
    [ -z "$NEXT_LABEL" ] && continue
    if ! credentials_ready "$NEXT_LABEL"; then
      log "SESSION: skipping scheduled reset autostart for $NEXT_LABEL — credentials missing"
      continue
    fi
    start_background_session "$NEXT_LABEL" "$SESSION_AUTOSTART_THRESHOLD" "$NEXT_RESET_AT" "reset"
    SCHEDULED_SESSION_STARTED="yes"
  done <<< "$DUE_LABELS"
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
  local JSON_DST KEY_DST
  JSON_DST=$(claude_json_backup "$LABEL")
  KEY_DST=$(keychain_backup "$LABEL")
  # Write via temp + atomic rename. A timer tick can overlap a manual run; a
  # non-atomic 'truncate then write' lets a concurrent reader see an empty file
  # (→ spurious missing_token). mv on the same filesystem is atomic.
  cp "$CLAUDE_JSON" "$JSON_DST.tmp.$$" && mv -f "$JSON_DST.tmp.$$" "$JSON_DST"
  if [ "$OS_TYPE" = "Darwin" ]; then
    # CRITICAL: there can be TWO keychain items labeled "Claude Code-credentials"
    # (Claude's own + an MCP-OAuth item). `-l ... -w` returns whichever it hits
    # first, which is sometimes the MCP item with NO claudeAiOauth. Writing that
    # into a backup corrupts it → missing_token → that account silently stops
    # polling. So: decode, VALIDATE claudeAiOauth.accessToken is present, and
    # only then atomically promote. Never overwrite a good backup with garbage.
    local SAVE_RESULT
    SAVE_RESULT=$(security find-generic-password -l "$KEYCHAIN_SERVICE" -w 2>/dev/null | python3 -c "
import binascii, json, sys
raw = sys.stdin.buffer.read().strip()
payload = raw
if raw and not raw.lstrip().startswith(b'{'):
    try:
        if all(b in b'0123456789abcdefABCDEF' for b in raw):
            dec = binascii.unhexlify(raw)
            if dec.lstrip().startswith(b'{'):
                payload = dec
    except Exception:
        pass
try:
    if json.loads(payload).get('claudeAiOauth', {}).get('accessToken'):
        open('$KEY_DST.tmp.$$', 'wb').write(payload)
        print('ok')
    else:
        print('no_claude_token')
except Exception:
    print('parse_error')
")
    if [ "$SAVE_RESULT" = "ok" ] && [ -s "$KEY_DST.tmp.$$" ]; then
      mv -f "$KEY_DST.tmp.$$" "$KEY_DST"
    else
      rm -f "$KEY_DST.tmp.$$"
      log "WARN: save $LABEL — live keychain returned $SAVE_RESULT (not a Claude credential); kept existing backup"
    fi
  else
    # Linux: credentials live in ~/.claude/.credentials.json
    [ -f "$LINUX_CREDENTIALS" ] && cp "$LINUX_CREDENTIALS" "$KEY_DST.tmp.$$" && mv -f "$KEY_DST.tmp.$$" "$KEY_DST"
  fi
  write_backup_metadata "$LABEL" "$REASON"
}

# Write a label's backup credential into the LIVE store (Keychain on macOS,
# ~/.claude/.credentials.json on Linux) WITHOUT touching ~/.claude.json.
# Used after refreshing the ACTIVE account's token so the live store and the
# backup never diverge — the root cause of the recurring "login needed" prompts
# (OAuth refresh tokens are single-use; rotating the backup invalidates the
# token still sitting in the live store).
write_live_credentials_from_backup() {
  local LABEL="$1"
  local KEYCHAIN_FILE
  KEYCHAIN_FILE=$(keychain_backup "$LABEL")
  [ ! -f "$KEYCHAIN_FILE" ] && return 1
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
    security delete-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
    security add-generic-password -U -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" \
      -l "$KEYCHAIN_SERVICE" -w "$KEYCHAIN_DATA" >/dev/null 2>&1 || return 1
  else
    cp "$KEYCHAIN_FILE" "$LINUX_CREDENTIALS"
  fi
  return 0
}

restore_credentials() {
  local LABEL="$1"
  local JSON_FILE KEYCHAIN_FILE
  JSON_FILE=$(claude_json_backup "$LABEL")
  KEYCHAIN_FILE=$(keychain_backup "$LABEL")

  [ -f "$JSON_FILE" ] || {
    log "RESTORE: missing claude.json backup for $LABEL"
    return 1
  }
  [ -f "$KEYCHAIN_FILE" ] || {
    log "RESTORE: missing keychain backup for $LABEL"
    return 1
  }

  # Save current account first
  local CUR_LABEL
  CUR_LABEL=$(account_label "$(current_account_email)")
  [ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"

  # Restore target — patch ONLY the account identity into the live ~/.claude.json,
  # never overwrite the whole file. The only account-specific key is oauthAccount;
  # everything else (mcpServers, projects, skillUsage, onboarding flags) is shared
  # machine state. Whole-file cp reverted that state to a stale per-account snapshot
  # on every switch, which looked like MCP servers / config "disappearing".
  if [ -f "$CLAUDE_JSON" ]; then
    python3 -c "
import json
live = json.load(open('$CLAUDE_JSON'))
backup = json.load(open('$JSON_FILE'))
if 'oauthAccount' in backup:
    live['oauthAccount'] = backup['oauthAccount']
else:
    live.pop('oauthAccount', None)
json.dump(live, open('$CLAUDE_JSON', 'w'), indent=2)
" 2>/dev/null || cp "$JSON_FILE" "$CLAUDE_JSON"
  else
    # No live file yet (fresh machine): seed it from the backup.
    cp "$JSON_FILE" "$CLAUDE_JSON"
  fi
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
    security delete-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
    security add-generic-password -U -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" \
      -l "$KEYCHAIN_SERVICE" -w "$KEYCHAIN_DATA" >/dev/null 2>&1 || {
        log "RESTORE: failed to update macOS keychain for $LABEL"
        return 1
      }
  else
    # Linux: write directly to credentials file
    cp "$KEYCHAIN_FILE" "$LINUX_CREDENTIALS"
  fi
  # NOTE: settings.json is intentionally NOT touched here. Account switches only
  # swap credentials. Proxy/personal settings switching is handled separately by
  # the SwiftBar use-personal / use-sap-proxy buttons (activate_settings).
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

  # List live Claude Code sessions on local AND remote host (if configured).
  # Output: host\tpid\tsession_id\tcwd\tmodel\tstarted_at\tname
  list_live_sessions() {
    # Local sessions
    local PID SESSION_ID CWD MODEL STARTED_AT NAME
    while IFS=$'\t' read -r PID SESSION_ID CWD MODEL STARTED_AT NAME; do
      [ -z "$SESSION_ID" ] && continue
      echo -e "local\t$PID\t$SESSION_ID\t$CWD\t$MODEL\t$STARTED_AT\t$NAME"
    done < <(list_active_claude_sessions)

    # Remote sessions (if REMOTE_HOST is configured)
    [ -z "$REMOTE_HOST" ] && return 0
    ssh -o ConnectTimeout=5 "$REMOTE_HOST" 'python3 -c "
import glob, json, os

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def last_model(sid):
    root = os.path.expanduser(\"~/.claude/projects\")
    for dp, _, fns in os.walk(root):
        if f\"{sid}.jsonl\" in fns:
            model = \"\"
            with open(os.path.join(dp, f\"{sid}.jsonl\")) as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        rec = json.loads(line)
                    except: continue
                    msg = rec.get(\"message\") or {}
                    if isinstance(msg, dict):
                        v = msg.get(\"model\", \"\")
                        if v: model = v
            return model
    return \"\"

for path in sorted(glob.glob(os.path.expanduser(\"~/.claude/sessions/*.json\")), key=os.path.getmtime, reverse=True):
    try: s = json.load(open(path))
    except: continue
    pid = int(s.get(\"pid\", 0) or 0)
    sid = s.get(\"sessionId\", \"\")
    cwd = s.get(\"cwd\", \"\")
    started = str(s.get(\"startedAt\", \"\"))
    name = s.get(\"name\", \"\")
    if not pid or not sid or not alive(pid): continue
    print(f\"remote\t{pid}\t{sid}\t{cwd}\t{last_model(sid)}\t{started}\t{name}\")
"' 2>/dev/null || true
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

# ── Adaptive polling: cadence scales with utilization so the 90% crossing is
# caught within one tick, while low-utilization accounts barely touch the API ──
should_poll() {
  local LAST_UTIL LAST_POLL_TIME THROTTLED_AT THROTTLE_COUNT
  if [ -f "$LAST_POLL_FILE" ]; then
    read -r LAST_UTIL LAST_POLL_TIME THROTTLED_AT THROTTLE_COUNT <<< $(python3 -c "
import json
d = json.load(open('$LAST_POLL_FILE'))
print(d.get('util', 0), d.get('time', 0), d.get('throttled_at', 0), d.get('throttle_count', 0))
" 2>/dev/null || echo "0 0 0 0")
  else
    echo "yes"; return
  fi
  local NOW ELAPSED
  NOW=$(date +%s)
  # 429 backoff: exponential per consecutive throttle (90s, 180s, 360s, 720s, cap 900s).
  # The first retry stays short so a genuine climb past 90% isn't missed.
  if [ "${THROTTLED_AT:-0}" -gt 0 ]; then
    local BACKOFF=90
    local C="${THROTTLE_COUNT:-1}"
    [ "$C" -lt 1 ] && C=1
    local I=1
    while [ "$I" -lt "$C" ] && [ "$BACKOFF" -lt 900 ]; do
      BACKOFF=$((BACKOFF * 2)); I=$((I + 1))
    done
    [ "$BACKOFF" -gt 900 ] && BACKOFF=900
    ELAPSED=$((NOW - THROTTLED_AT))
    [ "$ELAPSED" -lt "$BACKOFF" ] && echo "no" && return
  fi
  ELAPSED=$((NOW - LAST_POLL_TIME))
  local INTERVAL
  # The usage API throttles after ~2 rapid requests per account, so 60s (the
  # launchd tick floor) is the fastest safe rate. Cadence by utilization:
  if [ "${LAST_UTIL:-0}" -ge 75 ] 2>/dev/null; then
    INTERVAL=60    # Near the limit: poll every tick to catch the 90% crossing
  elif [ "${LAST_UTIL:-0}" -ge 50 ] 2>/dev/null; then
    INTERVAL=120   # Mid-range: every 2 minutes
  elif claude_session_active; then
    INTERVAL=120   # Conversation active (JSONL written in last 2 min): every 2 minutes
  else
    INTERVAL=300   # Idle or no active session: every 5 minutes
  fi
  [ "$ELAPSED" -ge "$INTERVAL" ] && echo "yes" || echo "no"
}

# ── API: fetch utilization for a given Bearer token ──
get_token() {
  local LABEL="$1"
  local CURRENT_LABEL
  CURRENT_LABEL=$(account_label "$(current_account_email)")
  # Never rotate the ACTIVE account's token while a Claude Code process owns it —
  # rotation consumes the refresh token in the live keychain and forces a re-login.
  # The active account's backup mirrors the live (valid) token via save_current_credentials.
  local SKIP_REFRESH="no"
  [ "$LABEL" = "$CURRENT_LABEL" ] && claude_process_running && SKIP_REFRESH="yes"
  [ "$OS_TYPE" = "Linux" ] && [ "$LABEL" = "$CURRENT_LABEL" ] && [ -f "$LINUX_CREDENTIALS" ] && SKIP_REFRESH="yes"
  # Known-dead refresh token: don't re-attempt the refresh on every read
  [ "$(refresh_dead_until "$LABEL")" -gt "$(date +%s)" ] && SKIP_REFRESH="yes"
  [ "$SKIP_REFRESH" = "no" ] && { refresh_backup_token "$LABEL" >/dev/null 2>&1 || true; }
  get_token_raw "$LABEL"
}

fetch_usage() {
  local TOKEN="$1"
  [ -z "$TOKEN" ] && echo "-1 none" && return
  python3 -c "
import urllib.request, urllib.error, json
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
except urllib.error.HTTPError as e:
  if e.code == 429:
    print('-2 none')
  else:
    print('-1 none')
except:
  print('-1 none')
" 2>/dev/null || echo "-1 none"
}

# ── Main ──
read_config

case "$1" in
  save)
    CUR_EMAIL=$(current_account_email)
    CUR_LABEL=${2:-$(account_label "$CUR_EMAIL")}
    if [ -z "$CUR_LABEL" ] || [ "$CUR_LABEL" = "unknown" ]; then
      log "SAVE: could not determine current account label"
      exit 1
    fi
    save_current_credentials "$CUR_LABEL" "manual-save"
    SAVE_RC=$?
    # A fresh login replaces the refresh chain — clear dead/backoff/relogin state
    clear_refresh_dead "$CUR_LABEL"
    clear_usage_backoff "$CUR_LABEL"
    clear_needs_local_relogin "$CUR_LABEL"
    exit $SAVE_RC
    ;;
  restore)
    if [ -z "$2" ]; then
      log "RESTORE: missing label"
      exit 1
    fi
    restore_credentials "$2"
    if [ $? -eq 0 ]; then
      update_config "active_account" "\"$2\""
      exit 0
    fi
    exit 1
    ;;
  trigger-limit)
    if [ -z "$2" ]; then
      echo "Usage: $0 trigger-limit <label>"
      exit 1
    fi
    # Direct API ping — opens the target's 5h window without touching the live login
    trigger_limit_for_label "$2"
    exit $?
    ;;
  repair-remote)
    # Repair a dead account on the remote machine by donating this machine's
    # working credential bundle. The refresh-token chain moves to the remote;
    # this machine should be re-logged-in for the label afterwards (easier than
    # logging in on a headless server).
    REPAIR_LABEL="$2"
    if [ -z "$REPAIR_LABEL" ]; then
      echo "Usage: $0 repair-remote <label>"
      exit 1
    fi
    if [ -z "$REMOTE_HOST" ]; then
      echo "repair-remote: no remote_host configured"
      exit 1
    fi
    if ! credentials_ready "$REPAIR_LABEL"; then
      log "REPAIR: no local credential backup for $REPAIR_LABEL"
      echo "repair-remote: no local backup for $REPAIR_LABEL"
      exit 1
    fi
    # Make sure we donate a fresh token (skip if active account while Claude runs)
    REPAIR_CUR_LABEL=$(account_label "$(current_account_email)")
    if [ "$REPAIR_LABEL" = "$REPAIR_CUR_LABEL" ] && claude_process_running; then
      log "REPAIR: $REPAIR_LABEL is the active account with Claude running — donating as-is (no refresh)"
    else
      refresh_backup_token "$REPAIR_LABEL" >/dev/null 2>&1 || true
    fi
    if scp -o ConnectTimeout=5 "$HOME/.claude-keychain-$REPAIR_LABEL.json" "$REMOTE_HOST":~/.claude-keychain-"$REPAIR_LABEL".json 2>/dev/null && \
       scp -o ConnectTimeout=5 "$HOME/.claude.json.$REPAIR_LABEL" "$REMOTE_HOST":~/.claude.json."$REPAIR_LABEL" 2>/dev/null; then
      [ ! -f "$HOME/.claude-meta-$REPAIR_LABEL.json" ] || scp -o ConnectTimeout=5 "$HOME/.claude-meta-$REPAIR_LABEL.json" "$REMOTE_HOST":~/.claude-meta-"$REPAIR_LABEL".json 2>/dev/null
      # Tell the remote to retry refreshes immediately and clear its dead/unauthorized state
      ssh -o ConnectTimeout=5 "$REMOTE_HOST" "python3 -c \"
import json, os
p = os.path.expanduser('~/.claude/account-usage-cache.json')
if os.path.exists(p):
    s = json.load(open(p))
    e = s.get('accounts', {}).get('$REPAIR_LABEL')
    if e:
        e.pop('refresh_dead_until', None)
        e.pop('backoff_until', None)
        e.pop('backoff_s', None)
        e['status'] = 'ok' if e.get('utilization') is not None else e.get('status', '')
        json.dump(s, open(p, 'w'), indent=2)
\"" 2>/dev/null
      # The donated refresh chain now belongs to the remote — stop rotating it
      # locally until a fresh local login replaces it (the save subcommand clears this).
      set_refresh_dead_until "$REPAIR_LABEL" 86400
      set_needs_local_relogin "$REPAIR_LABEL"
      log "REPAIR: donated credential bundle for $REPAIR_LABEL to $REMOTE_HOST — re-login locally for this account when convenient"
      echo "Donated $REPAIR_LABEL to $REMOTE_HOST. Now re-login on THIS machine for $REPAIR_LABEL (then run: $0 save $REPAIR_LABEL)."
      osascript -e "display notification \"$REPAIR_LABEL repaired on remote. Re-login locally, then Save.\" with title \"Claude Auto-Switch\"" 2>/dev/null
      exit 0
    else
      log "REPAIR: scp to $REMOTE_HOST failed for $REPAIR_LABEL"
      echo "repair-remote: transfer to $REMOTE_HOST failed"
      exit 1
    fi
    ;;
  register-auto-continue)
    register_auto_continue "$2" "$3" "$4" "$5" "$6"
    exit $?
    ;;
  list-active-sessions)
    list_active_claude_sessions
    exit 0
    ;;
  list-live-sessions)
    list_live_sessions
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
      get_usage_for_label "$CUR_LABEL" 30 >/dev/null
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
  restart-all-sessions)
    CUR_EMAIL=$(current_account_email)
    CUR_LABEL=$(account_label "$CUR_EMAIL")
    [ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"
    restart_all_sessions
    exit 0
    ;;
esac

# Keep the active account's backup in sync with the real live credential before
# any refresh or polling. This preserves rotated refresh tokens after a manual
# re-login and prevents the timer from falling back to stale backups.
CUR_EMAIL=$(current_account_email)
CUR_LABEL=$(account_label "$CUR_EMAIL")
[ "$CUR_LABEL" != "unknown" ] && save_current_credentials "$CUR_LABEL"

# Auto-clear any stale "re-login needed" reminder once a fresh local login is detected.
detect_local_relogin

# Keep backup tokens fresh on every timer run, independent of auto-switch state.
refresh_all_tokens
sync_tokens_cross_machine
maybe_run_scheduled_session
[ "$SCHEDULED_SESSION_STARTED" = "yes" ] && exit 0
maybe_run_auto_continue_sessions

[ "$ENABLED" != "True" ] && [ "$SESSION_AUTOSTART_ENABLED" != "True" ] && exit 0

# Proxy guard: if Claude Code is routed through a proxy (SAP AI Core / HAI),
# the claude.ai usage API is irrelevant and we must NOT switch claude.ai accounts.
# Detect via a non-default ANTHROPIC_BASE_URL in the live settings.json.
PROXY_ACTIVE=$(python3 -c "
import json, os
p = os.path.expanduser('~/.claude/settings.json')
try:
    env = json.load(open(p)).get('env', {})
except Exception:
    env = {}
base = env.get('ANTHROPIC_BASE_URL', '')
print('yes' if base and 'api.anthropic.com' not in base else 'no')
" 2>/dev/null || echo "no")
if [ "$PROXY_ACTIVE" = "yes" ]; then
  log "SKIP: proxy active (ANTHROPIC_BASE_URL set) — no claude.ai polling or switching"
  exit 0
fi

# ── Cache-threshold switch ──
# The usage cache is cross-device synced: if the OTHER device drove the shared
# account over the threshold, act on that reading even without a fresh local
# poll (fixes the wake-from-sleep case where the Mac sat on a 100% account).
if [ "$ENABLED" = "True" ]; then
  read -r C_STATUS C_UTIL C_RESETS C_AGE <<< $(peek_cached_usage "$CUR_LABEL")
  if [ "$C_STATUS" = "ok" ] && [ "$C_UTIL" != "none" ] && [ "$C_AGE" -le 300 ] 2>/dev/null && [ "$C_UTIL" -ge "$THRESHOLD" ] 2>/dev/null; then
    TARGET_INFO=$(find_ordered_switch_target "$CUR_LABEL" "$THRESHOLD")
    if [ -n "$TARGET_INFO" ]; then
      IFS='|' read -r TARGET TARGET_UTIL TARGET_RESETS_AT <<< "$TARGET_INFO"
      perform_switch "$CUR_LABEL" "$C_UTIL" "$C_RESETS" "$TARGET" "$TARGET_UTIL" "$(date +%s)" "cache-threshold"
      exit 0
    fi
  fi
fi

[ "$(should_poll)" != "yes" ] && exit 0

# Fetch usage for current account
CUR_TOKEN=$(get_token "$CUR_LABEL")
CURRENT_POLL_STATUS="ok"
read -r FETCH_STATUS UTIL RESETS_AT _SEVEN _SEVEN_AT <<< $(fetch_usage_detailed "$CUR_TOKEN")

# /oauth/usage throttled? Claude Code polls the SAME endpoint during a session
# and wins the per-account budget, leaving us 429 + a stale cache. Fall back to
# the Messages-header probe (separate endpoint, not throttled) to get the REAL
# utilization — this both keeps the display honest and lets the switch fire.
if [ "$FETCH_STATUS" = "rate_limited" ]; then
  read -r M_STATUS M_UTIL M_RESETS <<< $(fetch_usage_via_messages "$CUR_TOKEN")
  if [ "$M_STATUS" = "ok" ] && [ "$M_UTIL" != "none" ]; then
    FETCH_STATUS="ok"; UTIL="$M_UTIL"; RESETS_AT="$M_RESETS"
    log "POLL: /oauth/usage throttled — got real util via Messages headers: ${UTIL}%"
  fi
fi

if [ "$FETCH_STATUS" = "rate_limited" ]; then
  # Both endpoints unavailable — use cache, back off, DO NOT switch.
  CURRENT_POLL_STATUS="throttled"
  read -r UTIL RESETS_AT <<< $(python3 -c "
import json
d = json.load(open('$CACHE'))
u = d.get('usage', {}).get('five_hour', {})
print(int(u.get('utilization', 0)), u.get('resets_at', '') or 'none')
" 2>/dev/null || echo "0 none")
  # Back off exponentially so we don't keep hammering the throttled endpoint
  python3 -c "
import json, os, time
f = '$LAST_POLL_FILE'
d = json.load(open(f)) if os.path.exists(f) else {}
count = int(d.get('throttle_count', 0)) + 1
json.dump({'util': $UTIL, 'time': int(time.time()), 'throttled_at': int(time.time()), 'throttle_count': count}, open(f, 'w'))
" 2>/dev/null
  bump_usage_backoff "$CUR_LABEL" >/dev/null
  log "POLL: usage API throttled (429) for $CUR_LABEL — using cache (${UTIL}%), no switch"
elif [ "$FETCH_STATUS" != "ok" ]; then
  # Transient error (request_failed, unauthorized, http_5xx) — use cache, no backoff
  CURRENT_POLL_STATUS="api_error"
  log "POLL: API error ($FETCH_STATUS) for $CUR_LABEL — using cache"
  read -r UTIL RESETS_AT <<< $(python3 -c "
import json
d = json.load(open('$CACHE'))
u = d.get('usage', {}).get('five_hour', {})
print(int(u.get('utilization', 0)), u.get('resets_at', '') or 'none')
" 2>/dev/null || echo "0 none")
  # Don't touch the usage cache on transient errors — preserve last known values.
  # Update poll timer so retries happen on the normal interval (no throttled_at backoff).
  python3 -c "import json, time; json.dump({'util': $UTIL, 'time': int(time.time()), 'throttled_at': 0}, open('$LAST_POLL_FILE', 'w'))" 2>/dev/null
else
  # Success — update cache + poll timer + refresh active account backup.
  python3 -c "
import json, time
now = int(time.time())
d = {'account': '$CUR_LABEL', 'usage': {'five_hour': {'utilization': $UTIL, 'resets_at': '$RESETS_AT' if '$RESETS_AT' != 'none' else None}}, 'timestamp': int(time.time() * 1000)}
json.dump(d, open('$CACHE', 'w'), indent=2)
json.dump({'util': $UTIL, 'time': now, 'throttled_at': 0, 'throttle_count': 0}, open('$LAST_POLL_FILE', 'w'))
" 2>/dev/null
  update_usage_cache "$CUR_LABEL" "$UTIL" "$RESETS_AT" "ok" "live" "__KEEP__" "__KEEP__"
  clear_usage_backoff "$CUR_LABEL"
  save_current_credentials "$CUR_LABEL"
  log "POLL: $CUR_LABEL=${UTIL}%"
fi

# Throttled by the usage API — don't add more load or switch. Back off and wait.
[ "$CURRENT_POLL_STATUS" = "throttled" ] && exit 0

refresh_next_usage_cache "$CUR_LABEL"

maybe_autostart_session "$CUR_LABEL" "$UTIL" "$RESETS_AT"
schedule_session_after_reset "$CUR_LABEL" "$UTIL" "$RESETS_AT"

# Transient API errors: skip switch logic, backoff already set above
[ "$CURRENT_POLL_STATUS" = "api_error" ] && exit 0

[ "$ENABLED" != "True" ] && exit 0

NOW=$(date +%s)
ELAPSED=$((NOW - LAST_SWITCH_TIME))

if [ "$CURRENT_POLL_STATUS" != "ok" ]; then
  # Cooldown: don't switch on api-error if we switched for the same reason recently.
  # This prevents ping-pong between accounts when all accounts get transient errors.
  if [ "$ELAPSED" -lt 180 ]; then
    log "SKIP: api-error switch cooldown (${ELAPSED}s since last switch) — current=$CUR_LABEL"
    exit 0
  fi

  TARGET_INFO=$(find_ordered_switch_target "$CUR_LABEL" "$THRESHOLD")
  if [ -z "$TARGET_INFO" ]; then
    pause_all_sessions_for_full_capacity "$CUR_LABEL" "$RESETS_AT"
    log "SKIP: no usable account available after current account poll failure — current=$CUR_LABEL"
    exit 0
  fi

  IFS='|' read -r TARGET TARGET_UTIL TARGET_RESETS_AT <<< "$TARGET_INFO"
  perform_switch "$CUR_LABEL" "$UTIL" "$RESETS_AT" "$TARGET" "$TARGET_UTIL" "$NOW" "api-error"
  exit 0
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
