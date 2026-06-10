#!/bin/bash
#
# SwiftBar/xbar plugin for claude-auto-switch.
# Drop this next to claude-auto-switch.sh in your SwiftBar plugins folder
# (or symlink it). Refreshes every minute (the "1m" in the filename).
#
# Shows: active account + 5h/7d usage, one-click switch to any configured
# account, save credentials, start fresh 5h windows, recent switcher activity,
# and (if a remote_host is configured) the remote device's status.
#
# Reads only the switcher's own state files under ~/.claude — no network calls
# of its own (the daemon is the single API poller).

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
import re
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
log_path = os.path.join(home, '.claude', 'auto-switch.log')
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
    # '?' marks a reading taken while the usage API was throttled (rate_limited)
    suffix = '?' if status == 'rate_limited' else ''
    rem = format_remaining(entry.get('resets_at', ''))
    return f'{util}%{suffix} · {rem}' if rem else f'{util}%{suffix}'

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

# ── Switch account ──
# Swaps the live credential to the chosen account. NOTE: a running Claude Code
# session keeps its old token until it reloads — the switcher bumps settings.json
# to trigger that reload, but if the session doesn't pick it up, restart Claude
# Code (or /login) to land on the freshly-selected account.
others = [l for l in configured if l != email]
if others:
    print('---')
    print('Switch to')
    for label in others:
        print(f"--{label} — {badge(accounts.get(label, {}))} | bash='/bin/bash' param1={switcher_script!r} param2=restore param3={label!r} terminal=false refresh=true")

print('---')
print(f"Refresh usage cache | bash='/bin/bash' param1={switcher_script!r} param2=refresh-usage-cache-all terminal=false refresh=true")
print(f"Save credentials: {email} | bash='/bin/bash' param1={switcher_script!r} param2=save terminal=false refresh=true")

# ── 5h Session ──
# Starts a new Claude 5-hour usage window by sending a cheap haiku ping.
# This is not a Claude Code session restart — it does not touch any active
# chat. It simply opens a fresh 5-hour window for the account.
print('---')
print('5h Session')
for label in configured:
    print(f"--Restart limit: {label} | bash='/bin/bash' param1={switcher_script!r} param2=trigger-limit param3={label!r} terminal=false refresh=true")
print(f"--Restart all limits | bash='/bin/bash' param1={switcher_script!r} param2=start-all-sessions terminal=false refresh=true")

if configured:
    print('---')
    print('Configured order')
    for idx, label in enumerate(configured, start=1):
        account_entry = accounts.get(label, {})
        print(f'--{idx}. {label} — {badge(account_entry)}')

# ── Recent Activity ──
# Tail of the switcher log: polls, switches, throttle backoffs, opened windows.
def tail_activity(path, n=12):
    keep = re.compile(r'SWITCH|POLL|throttl|cache-threshold|LIMIT: triggered|SESSION: opened')
    try:
        lines = [l for l in open(path, errors='replace').read().splitlines() if keep.search(l)]
    except Exception:
        return []
    out = []
    for line in lines[-n:]:
        t = line[11:19] if len(line) > 19 and line[10] == ' ' else ''
        msg = (line[20:] if t else line).replace('|', '/')
        msg = re.sub(r'@[\w.]+', '', msg).replace(' (direct API)', '').replace('usage API ', '')
        out.append(f'{t}  {msg}' if t else msg)
    return list(reversed(out))   # newest first

activity = tail_activity(log_path)
if activity:
    print('---')
    print('Recent Activity')
    for line in activity:
        print(f'--{line} | size=12')

# ── Remote device status ──
remote_active = remote_status.get('active_account', '')
remote_host = remote_status.get('hostname', 'remote')
if remote_active:
    remote_entry = accounts.get(remote_active, {})
    remote_badge = badge(remote_entry)
    remote_status_val = remote_entry.get('status', '')
    error_color = ' | color=#e74c3c' if remote_status_val in ('unauthorized', 'missing_credentials', 'request_failed') else ''
    print('---')
    print(f'Remote ({remote_host})')
    print(f'--Active: {remote_active}{error_color}')
    print(f'--Usage: {remote_badge}{error_color}')
    if remote_status_val in ('unauthorized', 'missing_credentials'):
        print(f'--⚠ Login required on {remote_host} | color=#e74c3c')
        # One-click repair: donate this machine's working credential bundle.
        print(f"--🔧 Repair from here (push token) | bash='/bin/bash' param1={switcher_script!r} param2=repair-remote param3={remote_active!r} terminal=false refresh=true")
PY
