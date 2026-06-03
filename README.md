# Claude Account Switcher

Automatically rotate between multiple Claude.ai Pro accounts when the current account hits the 5-hour utilization limit. Keeps Claude Code running continuously without manual intervention.

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
  "accounts": [
    {"label": "work",     "email_pattern": "yourcompany.com"},
    {"label": "personal", "email_pattern": "gmail.com"}
  ]
}
```

- **`label`**: arbitrary name for the account (used for backup filenames)
- **`email_pattern`**: substring matched against the account's email address

### 3. Save credentials for each account

For **each** account you want to use, you need to save its credentials while it is the active account in Claude Code.

Run this once per account (while logged in as that account):

```bash
# Replace "work" with your account label
LABEL="work"
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

## Configuration Reference

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Master switch — set to `true` to activate |
| `threshold` | `90` | Switch at this utilization % (0-100) |
| `kitty_pause_on_switch` | `false` | Send pause/continue to Kitty terminal |
| `resume_before_reset_hours` | `0.5` | Send "continue" this many hours before the old account resets |
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
- Tokens auto-refresh while Claude Code is active; the script refreshes the backup on every successful poll

## Logs

```bash
tail -f ~/.claude/auto-switch.log
```

Log format: `YYYY-MM-DD HH:MM:SS LEVEL: message`

| Level | Meaning |
|-------|---------|
| `POLL` | Utilization check result |
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
