#!/bin/bash

SELF_PATH=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$0" 2>/dev/null)
SCRIPT_DIR=$(dirname "$SELF_PATH")
SWITCHER_SCRIPT="$SCRIPT_DIR/claude-auto-switch.sh"

if [ ! -f "$SWITCHER_SCRIPT" ]; then
  echo ":brain: Switcher missing"
  echo "---"
  echo "claude-auto-switch.sh not found next to this plugin."
  exit 0
fi

python3 - <<PY
import json
import os
import time
from datetime import datetime, timezone

try:
    from dateutil.parser import parse
except Exception:
    parse = None

home = os.path.expanduser('~')
claude_json = os.path.join(home, '.claude.json')
usage_cache = os.path.join(home, '.claude', 'account-usage-cache.json')
config_path = os.path.join(home, '.claude', 'auto-switch-config.json')
session_state_path = os.path.join(home, '.claude', 'session-autostart-state.json')
remote_status_path = os.path.join(home, '.claude', 'remote-status.json')
switcher_script = os.path.expanduser("$SWITCHER_SCRIPT")

def load_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return default

def current_email():
    data = load_json(claude_json, {})
    oauth = data.get('oauthAccount', {})
    if isinstance(oauth, dict):
        return oauth.get('emailAddress', 'unknown')
    return 'unknown'

def format_remaining(reset_at):
    if not reset_at or parse is None:
        return ''
    try:
        diff = int(parse(reset_at).timestamp() - time.time())
    except Exception:
        return ''
    if diff <= 0:
        return 'now'
    days, rem = divmod(diff, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days > 0:
        return f'{days}d {hours}h'
    if hours > 0:
        return f'{hours}h {minutes}m'
    return f'{minutes}m'

def badge(entry):
    status = entry.get('status', '')
    util = entry.get('utilization')
    if util is None:
        if status == 'rate_limited':
            rem = format_remaining(entry.get('resets_at', ''))
            return f'100% · {rem}' if rem else '100%'
        if status == 'unauthorized':
            return 'login needed'
        if status == 'missing_credentials':
            return 'missing credentials'
        if status == 'request_failed':
            return 'request failed'
        if status:
            return status.replace('_', ' ')
        return '—'
    rem = format_remaining(entry.get('resets_at', ''))
    return f'{util}% · {rem}' if rem else f'{util}%'

cache = load_json(usage_cache, {'accounts': {}})
accounts = cache.get('accounts', {}) if isinstance(cache, dict) else {}
config = load_json(config_path, {})
configured = [a.get('label', '') for a in config.get('accounts', []) if a.get('label', '')]
session_state = load_json(session_state_path, {})
auto_continue = session_state.get('auto_continue', {}) if isinstance(session_state, dict) else {}
scheduled_count = sum(1 for entry in auto_continue.values() if entry.get('status', 'scheduled') != 'sent')
remote_status = load_json(remote_status_path, {})

email = current_email()
entry = accounts.get(email, {}) if email != 'unknown' else {}
status = entry.get('status', '')
util = entry.get('utilization')

if util is not None:
    top = f':brain: {util}%'
elif status == 'rate_limited':
    top = ':brain: 100%'
elif status == 'unauthorized':
    top = ':brain: Login'
else:
    top = ':brain: Claude'

print(top)
print('---')
print(f'Current: {email}')
print(f'5h window: {badge(entry)}')

seven_day = entry.get('seven_day_utilization')
seven_day_reset = format_remaining(entry.get('seven_day_resets_at', ''))
if seven_day is not None:
    seven_line = f'7d window: {seven_day}%'
    if seven_day_reset:
        seven_line += f' · {seven_day_reset}'
    print(seven_line)

if scheduled_count:
    print(f'Auto-continue pending: {scheduled_count}')

print('---')
print(f"Refresh usage cache | bash='/bin/bash' param1={switcher_script!r} param2=refresh-usage-cache-all terminal=false refresh=true")
print(f"Save credentials: {email} | bash='/bin/bash' param1={switcher_script!r} param2=save terminal=false refresh=true")

# ── 5h Session ──
# Starts a new Claude 5-hour usage window by sending a cheap haiku ping.
# This is not a Claude Code session restart — it does not touch any active
# chat. It simply opens a fresh 5-hour window for the account.
print('---')
print('5h Session | color=#7f8c8d')
for label in configured:
    print(f"--Restart limit: {label} | bash='/bin/bash' param1={switcher_script!r} param2=trigger-limit param3={label!r} terminal=false refresh=true")
print(f"--Restart all limits | bash='/bin/bash' param1={switcher_script!r} param2=start-all-sessions terminal=false refresh=true")

if configured:
    print('---')
    print('Configured order | color=#7f8c8d')
    for idx, label in enumerate(configured, start=1):
        account_entry = accounts.get(label, {})
        print(f'--{idx}. {label} — {badge(account_entry)}')

# ── Remote device status ──
remote_active = remote_status.get('active_account', '')
remote_host = remote_status.get('hostname', 'remote')
if remote_active:
    remote_entry = accounts.get(remote_active, {})
    remote_badge = badge(remote_entry)
    remote_status_val = remote_entry.get('status', '')
    # Flag login errors with a warning color
    error_color = ' | color=#e74c3c' if remote_status_val in ('unauthorized', 'missing_credentials', 'request_failed') else ''
    print('---')
    print(f'Remote ({remote_host}) | color=#7f8c8d')
    print(f'--Active: {remote_active}{error_color}')
    print(f'--Usage: {remote_badge}{error_color}')
    if remote_status_val in ('unauthorized', 'missing_credentials'):
        print(f'--⚠ Login required on {remote_host} | color=#e74c3c')
PY