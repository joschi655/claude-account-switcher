# Claude Code auto Account Switcher

Automatically rotate between multiple Claude.ai Pro accounts when the current account hits the 5-hour utilization limit. Keeps Claude Code running continuously without manual intervention and session stays active while the account changes. Claude Code will just continue with its session.

## How It Works

Claude.ai Pro has a 5-hour rolling usage window. When your current account reaches the configured threshold (default: 90%), the script:

1. Saves the current account's credentials
2. Restores the next account's credentials into `~/.claude.json` and macOS Keychain
3. Optionally sends a `pause` message to a running Kitty terminal session
4. Schedules a `continue` message timed to when the original account resets

Supports **N accounts** — accounts rotate in the order defined in the config.

## Requirements

- macOS (uses Keychain and launchd)
- Claude Code installed and signed in to at least one account
- Python 3 (`brew install python3`)
- `python-dateutil` (`pip3 install python-dateutil`)
- Optional: [Kitty terminal](https://sw.kovidgoyal.net/kitty/) for auto-pause/resume

## Setup

### 1. Install

```bash
git clone https://github.com/YOUR_USERNAME/claude-account-switcher
cd claude-account-switcher
./install.sh
```

### 2. Configure

```bash
cp config.example.json ~/.claude/auto-switch-config.json
```

Edit `~/.claude/auto-switch-config.json`:

```json
{
  "enabled": false,
  "threshold": 90,
  "session_autostart_enabled": false,
  "session_autostart_threshold": 70,
  "session_autostart_hour": 6,
  "accounts": [
    {"label": "work@example.com"},
    {"label": "personal@gmail.com"}
  ]
}
```

- **`label`**: the full account email address (used for backup filenames and matching)

### 3. Save credentials for each account

For **each** account you want to use, you need to save its credentials while it is the active account in Claude Code.

Run this once per account (while logged in as that account):

```bash
# Replace with the full account email address
LABEL="work@example.com"
cp ~/.claude.json ~/.claude.json.$LABEL
security find-generic-password -l "Claude Code-credentials" -w > ~/.claude-keychain-$LABEL.json
```

> **Why?** Claude Code stores tokens in `~/.claude.json` and macOS Keychain. The switcher copies these files to restore each account instantly without needing to re-authenticate.

### 4. Enable

```bash
# Edit the config and set "enabled": true
nano ~/.claude/auto-switch-config.json
```

### 5. Verify

```bash
tail -f ~/.claude/auto-switch.log
```

You should see `POLL: work=XX%` lines every minute (more frequently above 50%).

## Session Autostart (Optional)

You can let the switcher launch a cheap Claude CLI run automatically using a command like:

```bash
claude -p "test" \
  --model haiku \
  --allowedTools "Read" \
  --max-turns 1 \
  --output-format json
```

This is useful if you want to:

1. Start the first lightweight session of the day at a fixed hour, such as 6:00.
2. Trigger a new cheap run after a window is already heavily used, for example above 70%, once no interactive `claude` process is running anymore.

Example config:

```json
{
  "session_autostart_enabled": true,
  "session_autostart_threshold": 70,
  "session_autostart_hour": 6,
  "session_autostart_prompt": "test",
  "session_autostart_model": "haiku",
  "session_autostart_allowed_tools": "Read",
  "session_autostart_max_turns": 1,
  "session_autostart_output_format": "json"
}
```

Behavior:

- Starts at most once per account per day after the configured hour.
- Can also start once per reset window when utilization reaches the configured threshold.
- Never starts while another `claude` process is already running.
- Writes one log file per run to `~/.claude/session-autostart-<timestamp>.log`.

## Ubuntu Auto-Continue For Interactive Sessions

On Ubuntu you can now mark a specific Claude Code session so it automatically receives `continue` once the current account window resets.

This no longer depends on Kitty sockets. The switcher resolves the active Claude `sessionId` from `~/.claude/sessions/*.json`, looks up the last used model from the persisted JSONL session log, and resumes with `--dangerously-skip-permissions`.

Run this inside the session directory you want to resume later:

```bash
claude-auto-switch.sh register-auto-continue hermes-main
```

What it does:

- Uses the current Claude account label by default.
- Resolves the active Claude session for the current working directory.
- Reuses the last model that session actually used.
- Resumes with `claude --resume <session-id> --model <last-model> --dangerously-skip-permissions -p "continue"`.
- Falls back to the known reset time from the local usage caches.
- Stores the registration in `~/.claude/session-autostart-state.json`.
- When the timer script next sees that the reset time has passed, it sends `continue` back into that exact Claude session.

Useful commands:

```bash
# Register the active Claude session in the current directory for auto-continue after reset
claude-auto-switch.sh register-auto-continue hermes-main

# Explicit form: session name, account label, session id, continue text, reset_at
claude-auto-switch.sh register-auto-continue hermes-main work@example.com 9ecf0422-9d1b-4655-a08a-b681d2ebf40e continue 2026-06-07T18:30:00+00:00

# Inspect active Claude sessions the switcher can target
claude-auto-switch.sh list-active-sessions

# Show scheduled auto-continue sessions
claude-auto-switch.sh list-auto-continue

# Remove one scheduled auto-continue session
claude-auto-switch.sh clear-auto-continue hermes-main
```

Requirements:

- The timer/service must keep running on Ubuntu so the due `continue` can be delivered.
- The target Claude session must already have written a persisted session record and at least one model-bearing response.
- If no reset time is known yet, run a usage refresh first: `claude-auto-switch.sh refresh-usage-cache-all`.

## Configuration Reference

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Master switch — set to `true` to activate |
| `threshold` | `90` | Switch at this utilization % (0-100) |
| `kitty_pause_on_switch` | `false` | Send pause/continue to Kitty terminal |
| `resume_before_reset_hours` | `0.5` | Send "continue" this many hours before the old account resets |
| `session_autostart_enabled` | `false` | Enable automatic cheap `claude -p` session starts |
| `session_autostart_threshold` | `70` | Start a cheap run once utilization reaches this % |
| `session_autostart_hour` | `6` | Earliest hour of day for the daily autostart |
| `session_autostart_prompt` | `test` | Prompt used for the cheap autostart run |
| `session_autostart_model` | `haiku` | Model used for the cheap autostart run |
| `session_autostart_allowed_tools` | `Read` | Allowed tools string passed to `claude` |
| `session_autostart_max_turns` | `1` | Max turns for the cheap autostart run |
| `session_autostart_output_format` | `json` | Output format for the cheap autostart run |
| `preferred_return_threshold` | `70` | Prefer switching back to the first account in config order once it is below this utilization |
| `accounts` | `[]` | Ordered list of accounts to rotate through |
| `active_account` | `""` | Managed automatically — current active label |
| `last_switch_time` | `0` | Unix timestamp of last switch (cooldown tracking) |

## Kitty Auto-Pause (Optional)

If you run long Claude Code agent sessions in Kitty, enable this to automatically pause the session on switch and resume it when the old account resets:

```json
{
  "kitty_pause_on_switch": true,
  "resume_before_reset_hours": 0.5
}
```

Requires [Kitty's remote control](https://sw.kovidgoyal.net/kitty/remote-control/) to be enabled. In `~/.config/kitty/kitty.conf`:

```
allow_remote_control yes
listen_on unix:/tmp/kitty-SESSION_NAME
```

Update the `find_kitty_socket` function in `claude-auto-switch.sh` to match your socket naming convention.

## Credentials & Security

- Credentials are stored locally in `~/.claude-keychain-<label>.json` (raw OAuth tokens)
- **Never commit these files** — they are in `.gitignore`
- Tokens auto-refresh while Claude Code is active; the script also refreshes backup tokens proactively on timer runs when they are close to expiry

## Logs

```bash
tail -f ~/.claude/auto-switch.log
```

Log format: `YYYY-MM-DD HH:MM:SS LEVEL: message`

| Level | Meaning |
|-------|---------|
| `POLL` | Utilization check result |
| `SESSION` | Cheap Claude CLI session auto-started |
| `SWITCH` | Account was switched |
| `SKIP` | Switch skipped (reason follows) |
| `WARN` | Non-fatal warning |
| `TIMER` | Resume timer scheduled |
| `RESUME` | "continue" sent to Kitty |
| `KITTY` | Kitty message status |

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.claude.auto-switch.plist
rm ~/Library/LaunchAgents/com.claude.auto-switch.plist
```

## License

MIT
