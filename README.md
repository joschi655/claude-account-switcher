# Claude Code auto Account Switcher

Rotate between multiple Claude.ai accounts so Claude Code can keep working when one account reaches its rolling usage limit.

<img width="763" height="495" alt="Claude account switcher menu" src="https://github.com/user-attachments/assets/78d22d14-fcd0-4a5a-9df6-3cea1e4f689b" />

The project is built around a single timer script, [claude-auto-switch.sh](./claude-auto-switch.sh), which:

- polls Claude usage,
- keeps per-account credential backups fresh,
- switches accounts in configured order,
- optionally pauses active work during a switch,
- optionally resumes work when the old account resets,
- and can auto-start or auto-continue lightweight Claude sessions.

This repository is public. The examples below use placeholder emails and generic paths only. Do not publish real account labels, tokens, credential backups, hostnames, or copied session data.

## What It Does

Main capabilities:

- Automatic account rotation once the active account reaches a configured threshold such as `90%`.
- Ordered fallback across any number of configured accounts.
- Preference to switch back to an earlier account in the configured order once it is usable again.
- Per-account usage cache for both the 5-hour window and the 7-day window.
- Backup credential refresh, including rotated OAuth refresh tokens.
- Cross-platform credential handling:
  - macOS reads and writes Claude Code credentials through Keychain.
  - Linux reads and writes Claude Code credentials through `~/.claude/.credentials.json`.
- Optional Kitty-based pause and continue flow during switches.
- Optional auto-continue for interactive Claude sessions after a reset time is reached.
- Optional cheap background Claude runs for warming or verifying a fresh window.
- Log files and state files that can be consumed by an external menu bar or status UI.

## How Rotation Works

At a high level, the timer loop does this every run:

1. Read config from `~/.claude/auto-switch-config.json`.
2. Save the live account state back into that account's backup files.
3. Refresh backup tokens that are close to expiry.
4. Poll usage for the active account and one or more backup accounts.
5. If a preferred earlier account is below the return threshold, switch back to it.
6. If the active account is above the switch threshold, pick the next usable account in config order and switch.
7. If pause/continue is enabled, pause the current work and schedule a later `continue`.

If no configured account is below threshold, the script does not blindly switch. It records that state, can broadcast a pause to active sessions, and waits for the next reset window.

## Account Order

Account order matters.

The script treats the `accounts` array in `~/.claude/auto-switch-config.json` as the source of truth for rotation priority.

- When the active account crosses the switch threshold, the script looks for the next usable account in the configured order.
- It does not pick a random account.
- It does not automatically optimize for “lowest usage anywhere” first.
- It can prefer returning to an earlier account in the list once that account is below `preferred_return_threshold`.

That means the order should reflect your actual preference. For example, you might want:

- a primary personal account first,
- one or more overflow accounts after that,
- and rarely used backup accounts last.

Example:

```json
{
  "preferred_return_threshold": 70,
  "accounts": [
    {"label": "primary@example.com"},
    {"label": "secondary@example.com"},
    {"label": "overflow@example.com"}
  ]
}
```

In that setup, the script will rotate forward in that order, and later prefer moving back toward `primary@example.com` once it is sufficiently recovered.

## Files and State

The script manages a few local files in your Claude home directory:

- `~/.claude/auto-switch-config.json`: main config
- `~/.claude/auto-switch.log`: rotation log
- `~/.claude/account-usage-cache.json`: per-account usage cache
- `~/.claude/stats-cache.json`: last active-account usage snapshot
- `~/.claude/session-autostart-state.json`: scheduled session starts and auto-continue state
- `~/.claude/auto-switch-refresh-audit.log`: refresh-token audit log
- `~/.claude.json.<label>`: backup of the account metadata file
- `~/.claude-keychain-<label>.json`: backup of the account credential payload
- `~/.claude-meta-<label>.json`: metadata about each saved backup

These backup files contain sensitive credentials. Keep them local.

## Platform Support

### macOS

macOS is the primary turnkey setup:

- installer included,
- LaunchAgent included,
- Keychain integration built in,
- optional SwiftBar or BitBar style menu bar integration supported through the generated caches and logs,
- optional Kitty pause/resume flow supported.

### Linux

Linux is supported directly by the repo too:

- Claude credentials live in `~/.claude/.credentials.json` instead of Keychain.
- The same config and cache files are used.
- the installer now ships and installs a `systemd --user` service plus timer when `systemctl --user` is available,
- otherwise you can still run the script from `cron`, `nohup`, or another scheduler.
- Auto-continue for interactive Claude sessions is especially useful on Linux because it resumes a known Claude session directly from saved session state.

## Menu Bar / Status UI Integration

This repository does not bundle a menu bar app, but it is designed to work well with one.

An external menu bar script can read:

- `~/.claude/account-usage-cache.json` for per-account 5-hour and 7-day usage,
- `~/.claude/session-autostart-state.json` for scheduled session starts and auto-continue jobs,
- `~/.claude/auto-switch.log` for recent switch events,
- `~/.claude/auto-switch-refresh-audit.log` for token refresh health.

Typical menu bar features built on top of those files include:

- showing the current active account,
- showing utilization and time-left until reset,
- showing all configured accounts in order,
- exposing a manual “save credentials” or “switch account” action,
- showing whether an auto-continue or resume is pending.

If you publish screenshots of a menu bar integration, scrub email addresses, reset times, machine names, and any account ordering that you consider private.

### SwiftBar quick setup

This repo now includes a minimal SwiftBar plugin: [swiftbar-claude-account-switcher.1m.sh](./swiftbar-claude-account-switcher.1m.sh).

Quick setup on macOS:

1. Install [SwiftBar](https://swiftbar.app/).
2. Keep this repo in a stable local path.
3. Symlink the plugin into your SwiftBar plugins directory.

Example:

```bash
mkdir -p "$HOME/Library/Application Support/SwiftBar/Plugins"
ln -sf \
  "/path/to/claude-account-switcher/swiftbar-claude-account-switcher.1m.sh" \
  "$HOME/Library/Application Support/SwiftBar/Plugins/swiftbar-claude-account-switcher.1m.sh"
chmod +x "/path/to/claude-account-switcher/swiftbar-claude-account-switcher.1m.sh"
```

What it shows:

- a compact menu bar icon and current usage badge,
- the current account, with 5-hour and 7-day usage state,
- one-click **switch** to any configured account,
- per-account **"restart limit"** actions to open a fresh 5-hour window (cheap haiku ping, no chat disruption),
- a **Recent Activity** view (polls, switches, throttle backoffs) tailed from the log,
- the configured account order with each account's usage,
- pending auto-continue jobs,
- and, if a `remote_host` is configured, the remote device's active account and login health (with a one-click "repair from here" action).

Menu actions call the switcher directly (`restore`, `save`, `trigger-limit`, `refresh-usage-cache-all`, `start-all-sessions`, `repair-remote`). It reads only the switcher's local state files — it makes no API calls of its own (the daemon is the single poller).

Note: switching the account swaps the live credential, but a Claude Code session that is already running keeps its old token until it reloads. The switcher bumps `settings.json` to trigger that reload; if a running session doesn't pick it up, restart Claude Code (or `/login`) to land on the freshly selected account.

## Who This Is Great For

This project is especially useful for:

- people with access to multiple Claude.ai subscriptions who want predictable rotation instead of manual re-login,
- people who run long coding or agent sessions and want work to continue across reset windows,
- people who leave Claude Code running overnight and want the tool to automatically start or resume a fresh 5-hour session after the limit resets,
- people running remote Linux boxes where a headless timer plus session auto-continue is more useful than a desktop UI,
- people who want visibility into usage via logs, cache files, or a menu bar integration,
- people with only one Claude account who still want automatic pause, wait, and continue behavior around reset times.

### Single-account value

This is not only a multi-account tool.

With one Claude account, the project is still useful because it can:

- watch the active window,
- pause work when the account is exhausted,
- remember when the reset window returns,
- automatically start a new session when a fresh 5-hour window becomes available,
- and resume a real Claude session with `continue` after the reset.

That makes it useful for long-running work, overnight tasks, and unattended recovery even if you never rotate between accounts.

### Shared-account scenarios

Some users may also find this useful when they have legitimate access to more than one Claude.ai subscription, including accounts that are not regularly used with Claude Code.

For example, if someone only uses the Claude chat product and does not use Claude Code, a shared setup could make otherwise idle Claude Code capacity more usable in practice.

Use common sense here:

- only use accounts you are authorized to use,
- get explicit consent from the account owner,
- do not bypass provider controls,
- and make sure your use complies with Anthropic's terms, billing rules, and any applicable workplace or team policies.

## Requirements

Core requirements:

- Claude Code installed
- at least one Claude account already signed in
- `bash`
- `python3`
- `python-dateutil`

Optional:

- [Kitty](https://sw.kovidgoyal.net/kitty/) if you want terminal pause/continue integration
- a menu bar host such as SwiftBar if you want a visual status UI on macOS

## macOS Setup

### 1. Clone

```bash
git clone https://github.com/YOUR_USERNAME/claude-account-switcher.git
cd claude-account-switcher
```

### 2. Install dependencies

```bash
brew install python3
pip3 install python-dateutil
```

### 3. Run the installer

```bash
./install.sh
```

This:

- marks the script executable,
- installs a LaunchAgent from [com.claude.auto-switch.plist.template](./com.claude.auto-switch.plist.template),
- creates a default config if you do not already have one,
- and starts the timer with a 60-second interval.

### 4. Edit your config

Example:

```json
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
  "preferred_return_threshold": 70,
  "accounts": [
    {"label": "work@example.com"},
    {"label": "personal@example.com"}
  ],
  "active_account": "",
  "last_switch_time": 0,
  "other_account_resets_at": ""
}
```

### 5. Save credentials for each account

For each account you want to rotate through:

1. Sign in to Claude Code as that account.
2. Save `~/.claude.json` to a label-specific backup.
3. Export the Claude Code Keychain payload to a label-specific backup.

Example:

```bash
LABEL="work@example.com"
cp ~/.claude.json ~/.claude.json."$LABEL"
security find-generic-password -l "Claude Code-credentials" -w > ~/.claude-keychain-"$LABEL".json
```

The script will maintain additional metadata automatically in `~/.claude-meta-<label>.json`.

### 6. Enable switching

Set `enabled` to `true` in `~/.claude/auto-switch-config.json`.

### 7. Verify

```bash
tail -f ~/.claude/auto-switch.log
```

You should see poll activity and, later, switch decisions.

## Linux Setup

The script works on Linux directly from this repo.

### 1. Clone and install Python dependency

```bash
git clone https://github.com/YOUR_USERNAME/claude-account-switcher.git
cd claude-account-switcher
python3 -m pip install python-dateutil
chmod +x claude-auto-switch.sh
```

### 2. Run the installer

```bash
./install.sh
```

This:

- marks the script executable,
- creates `~/.claude/auto-switch-config.json` if it does not exist,
- installs `com.claude.auto-switch.service` and `com.claude.auto-switch.timer` into `~/.config/systemd/user/`,
- and enables the timer automatically when `systemctl --user` is available.

If `systemctl --user` is not available in your environment, the installer still leaves the repo usable and prints a cron fallback.

### 3. Save credentials for each account

On Linux, Claude Code stores credentials in `~/.claude/.credentials.json`.

For each account:

```bash
LABEL="work@example.com"
cp ~/.claude.json ~/.claude.json."$LABEL"
cp ~/.claude/.credentials.json ~/.claude-keychain-"$LABEL".json
```

The filename stays `claude-keychain-<label>.json` for compatibility with the script, even on Linux.

### 4. Verify

```bash
tail -f ~/.claude/auto-switch.log
```

If you are using systemd user units, these are useful too:

```bash
systemctl --user status com.claude.auto-switch.timer
journalctl --user -u com.claude.auto-switch.service -f
```

## Pause and Continue

There are two distinct pause/continue mechanisms.

### 1. Kitty auto-pause on switch

If `kitty_pause_on_switch` is enabled, the script can:

- switch to another account,
- wait briefly,
- send a `pause` message to the active work session,
- and later send `continue` shortly before the original account resets.

Relevant config:

```json
{
  "kitty_pause_on_switch": true,
  "resume_before_reset_hours": 0.5
}
```

Kitty setup example:

```conf
allow_remote_control yes
listen_on unix:/tmp/kitty-main
```

The script currently discovers sockets under `/tmp/kitty-*`. If your naming is different, adjust `find_kitty_socket` or `find_all_kitty_sockets` in [claude-auto-switch.sh](./claude-auto-switch.sh).

### 2. Auto-continue for interactive Claude sessions

This is a separate feature. It does not depend on Kitty. Instead, it stores a mapping from account reset time to a specific Claude session ID, model, and working directory, then later resumes that exact session with a prompt such as `continue`.

This is useful when:

- you want to resume a real Claude session rather than just sending text to a terminal,
- you are running Linux or a remote box,
- you want deterministic resume behavior tied to the session ID.

Register the current session:

```bash
./claude-auto-switch.sh register-auto-continue my-session
```

Useful commands:

```bash
./claude-auto-switch.sh list-active-sessions
./claude-auto-switch.sh list-auto-continue
./claude-auto-switch.sh clear-auto-continue my-session
```

Explicit registration form:

```bash
./claude-auto-switch.sh register-auto-continue my-session work@example.com SESSION_ID continue 2026-06-08T18:30:00+00:00
```

When the timer sees that reset time has passed, it runs a one-shot Claude resume command against that exact session.

## Session Auto-Start

The script can also automatically start a fresh Claude session when a new 5-hour window is available.

In practice, this means it can kick off a new background session after reset instead of waiting for you to come back manually.

Typical use cases:

- start one low-cost run each day after a chosen hour,
- start a fresh 5-hour session once a reset window becomes available,
- or trigger a lightweight call after usage reaches a threshold.

Relevant config:

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

The script will not start a cheap run while another `claude` process is already active.

This is especially useful for unattended or overnight workflows: the timer can notice that the account has reset, automatically start a new session, and then let your pause/continue or auto-continue flow carry the work forward.

There is also a helper command to start one synchronous run for every configured account:

```bash
./claude-auto-switch.sh start-all-sessions
```

## Manual Commands

The script supports a small CLI surface in addition to the timer mode.

Refresh caches:

```bash
./claude-auto-switch.sh refresh-usage-cache
./claude-auto-switch.sh refresh-usage-cache-all
```

Session helpers:

```bash
./claude-auto-switch.sh list-active-sessions
./claude-auto-switch.sh register-auto-continue my-session
./claude-auto-switch.sh list-auto-continue
./claude-auto-switch.sh clear-auto-continue my-session
./claude-auto-switch.sh start-all-sessions
```

When run with no subcommand, the script performs one timer iteration.

## Configuration Reference

| Key | Default | Meaning |
|---|---:|---|
| `enabled` | `false` | Enables automatic switching |
| `threshold` | `90` | Switch away from the current account at or above this utilization |
| `kitty_pause_on_switch` | `false` | Enable Kitty-based pause/resume flow |
| `resume_before_reset_hours` | `0.5` | Send `continue` this many hours before the old account resets |
| `session_autostart_enabled` | `false` | Enable cheap automatic Claude runs |
| `session_autostart_threshold` | `70` | Threshold that can trigger a cheap run |
| `session_autostart_hour` | `6` | Earliest hour for the daily cheap run |
| `session_autostart_prompt` | `test` | Prompt used for the cheap run |
| `session_autostart_model` | `haiku` | Model for the cheap run |
| `session_autostart_allowed_tools` | `Read` | Allowed tools passed to Claude |
| `session_autostart_max_turns` | `1` | Max turns for the cheap run |
| `session_autostart_output_format` | `json` | Output format for the cheap run |
| `preferred_return_threshold` | `70` | Switch back to an earlier configured account once it drops below this threshold |
| `accounts` | `[]` | Ordered list of account labels |
| `active_account` | `""` | Managed by the script |
| `last_switch_time` | `0` | Cooldown tracking to avoid rapid flip-flopping |
| `other_account_resets_at` | `""` | Extra state field used by companion status UIs |

## Logs

Main log:

```bash
tail -f ~/.claude/auto-switch.log
```

Refresh audit:

```bash
tail -f ~/.claude/auto-switch-refresh-audit.log
```

Typical log prefixes:

- `POLL`: usage poll result
- `SWITCH`: account switch happened
- `SKIP`: no switch taken
- `TOKEN`: token refresh event
- `SESSION`: auto-start session event
- `CONTINUE`: auto-continue registration or send result
- `TIMER`: scheduled resume time
- `RESUME`: scheduled continue sent
- `PAUSE`: full-capacity pause broadcast
- `KITTY`: Kitty transport details

## Security Notes

This project handles real Claude OAuth credentials. Treat it accordingly.

- Never commit `~/.claude.json.*`, `~/.claude-keychain-*.json`, or `~/.claude-meta-*.json`.
- Never publish screenshots containing real account labels or session IDs.
- Avoid hardcoding hostnames, SSH aliases, organization IDs, or personal account labels into docs or scripts you plan to share.
- Review your local shell history if you manually copied credentials around.

## Uninstall on macOS

```bash
launchctl unload ~/Library/LaunchAgents/com.claude.auto-switch.plist
rm ~/Library/LaunchAgents/com.claude.auto-switch.plist
```

## License

MIT
