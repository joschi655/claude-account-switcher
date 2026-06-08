#!/bin/bash

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWITCHER_SCRIPT="$REPO_DIR/claude-auto-switch.sh"
CACHE="$HOME/.claude/account-usage-cache.json"
CLAUDE_JSON="$HOME/.claude.json"

python3 - <<'PY'
import json
import os
import time
from datetime import datetime

cache_path = os.path.expanduser('~/.claude/account-usage-cache.json')
claude_json_path = os.path.expanduser('~/.claude.json')

def format_remaining(reset_at):
    if not reset_at:
        return ''
    try:
        diff = int(datetime.fromisoformat(reset_at).timestamp() - time.time())
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

current_email = 'unknown'
if os.path.exists(claude_json_path):
    try:
        current_email = json.load(open(claude_json_path)).get('oauthAccount', {}).get('emailAddress', 'unknown')
    except Exception:
        current_email = 'unknown'

accounts = {}
if os.path.exists(cache_path):
    try:
        accounts = (json.load(open(cache_path)).get('accounts', {}) or {})
    except Exception:
        accounts = {}

entry = accounts.get(current_email, {}) if current_email != 'unknown' else {}
status = entry.get('status', '')
util = entry.get('utilization')
reset_at = entry.get('resets_at', '') or ''
seven_day_util = entry.get('seven_day_utilization')
seven_day_reset = entry.get('seven_day_resets_at', '') or ''

if util is not None:
    title = f'Claude {util}%'
elif status == 'rate_limited':
    title = 'Claude 100%'
elif status == 'unauthorized':
    title = 'Claude Login'
else:
    title = 'Claude --'

print(f'{title} | sfimage=brain.head.profile')
print('---')
print(f'Current: {current_email}')
print(f'Status: {status or "unknown"}')

five_line = '5h: '
if util is not None:
    five_line += f'{util}%'
elif status == 'rate_limited':
    five_line += '100%'
else:
    five_line += '--'
remaining = format_remaining(reset_at)
if remaining:
    five_line += f' · {remaining}'
print(five_line)

seven_line = '7d: '
if seven_day_util is not None:
    seven_line += f'{seven_day_util}%'
else:
    seven_line += '--'
remaining_7d = format_remaining(seven_day_reset)
if remaining_7d:
    seven_line += f' · {remaining_7d}'
print(seven_line)

print('---')
for label in sorted(accounts.keys()):
    account = accounts.get(label, {}) or {}
    account_status = account.get('status', 'unknown')
    account_util = account.get('utilization')
    label_line = label
    if account_util is not None:
        label_line += f' — {account_util}%'
    elif account_status == 'rate_limited':
        label_line += ' — 100%'
    elif account_status:
        label_line += f' — {account_status}'
    print(label_line)
PY

echo "---"
echo "Refresh Cache | bash='$SWITCHER_SCRIPT' param1=refresh-usage-cache-all terminal=false refresh=true"
