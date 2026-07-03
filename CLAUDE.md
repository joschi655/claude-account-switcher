# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A single-file bash daemon that rotates between multiple Claude.ai accounts when the active account hits a usage threshold. Runs every 60 seconds via launchd (macOS) or systemd (Linux).

## Running and Testing

```bash
# Run one timer iteration (the normal mode)
./claude-auto-switch.sh

# Manual subcommands
./claude-auto-switch.sh refresh-usage-cache
./claude-auto-switch.sh refresh-usage-cache-all
./claude-auto-switch.sh list-active-sessions
./claude-auto-switch.sh register-auto-continue <name>
./claude-auto-switch.sh list-auto-continue
./claude-auto-switch.sh clear-auto-continue <name>
./claude-auto-switch.sh start-all-sessions
./claude-auto-switch.sh save <label>
./claude-auto-switch.sh restore <label>
./claude-auto-switch.sh remove-account <label> [--purge]
./claude-auto-switch.sh sync-account <label> [--token-based]

# Install the timer
./install.sh

# Watch live log
tail -f ~/.claude/auto-switch.log
```

There are no tests and no build step. Validate changes by running the script directly and checking the log.

## Architecture

### Core Script: `claude-auto-switch.sh` (~2100 lines)

All logic lives in one file. The bottom of the script is the entry point — a `case` dispatch for subcommands, followed by the timer loop body.

**Timer loop order (no-subcommand path):**
1. `read_config` — load all config vars as shell globals from `~/.claude/auto-switch-config.json`
2. `save_current_credentials` — sync live credentials into the active account's backup files
3. `refresh_all_tokens` — proactively refresh OAuth tokens in all backups
4. `sync_tokens_cross_machine` — optional SSH-based push/pull of fresher tokens to `REMOTE_HOST`
5. `maybe_run_scheduled_session` / `maybe_run_auto_continue_sessions` — fire any pending auto-starts or auto-continues
6. `fetch_usage` — poll the Claude usage API for the active account
7. Priority-return check — switch back to an earlier (preferred) account if it has recovered below `preferred_return_threshold`
8. Token-account escape — if the active account is `token_based`, leave it for the highest-priority Pro account below threshold (reason `leave-token-account`); if none, stay parked. Runs before the threshold check.
9. Threshold check — switch to next available account if `UTIL >= THRESHOLD`

**Account priority & types:** the `accounts` array in config is the priority order (index 0 = highest). An account marked `"token_based": true` never reports a meaningful usage % (API-credit accounts — "empty is empty") — it's a last-resort account, pinned last in priority. The daemon parks on it only when no Pro account is available and switches away the moment one is (`is_token_account` helper + escape block in the timer loop). Remove accounts with `remove-account <label> [--purge]`; `--purge` also deletes the credential backup files and cleans every state file that tracks the label (usage cache, switch history, refresh-audit log, autostart state). Removing the active account is refused.

**Adding accounts + cross-machine transfer:** add on the primary machine via the SwiftBar "➕ Add account" → `/login` → "💾 Save credentials" flow, then add the label to the config `accounts` array (append at the end for token accounts, with `"token_based": true`). To propagate a fully-configured account to the remote machine, run `sync-account <label> [--token-based]` — it pushes the credential bundle **and** appends the label (with the flag) to the remote config's `accounts` list (idempotent; additive, unlike `repair-remote` which surrenders the local refresh chain).

### Config and State Files

All runtime state lives in `~/.claude/`:

| File | Purpose |
|------|---------|
| `auto-switch-config.json` | Main config (read every run) |
| `auto-switch.log` | Rolling log, capped at 5000 lines |
| `account-usage-cache.json` | Per-account 5-hour and 7-day usage |
| `stats-cache.json` | Last active-account usage snapshot |
| `session-autostart-state.json` | Auto-start and auto-continue registrations |
| `auto-switch-last-log.txt` | POLL/SKIP dedup state (suppress noise) |
| `auto-switch-last-poll.json` | Last poll timestamp for rate limiting |
| `token-sync-state.json` | Cross-machine sync timestamp |

Credential backup files live in `~HOME` (not `~/.claude/`):
- `~/.claude-keychain-<label>.json` — OAuth token payload
- `~/.claude.json.<label>` — Claude metadata file backup
- `~/.claude-meta-<label>.json` — metadata about the backup (written by `write_backup_metadata`)

### Platform Differences

**macOS** — primary platform:
- Credentials stored in Keychain; accessed via the `security` CLI
- Timer managed by launchd (`~/Library/LaunchAgents/com.claude.auto-switch.plist`)
- `save_current_credentials` exports the Keychain entry to the `.json` backup
- `restore_credentials` imports the `.json` backup back into Keychain

**Linux**:
- Credentials stored in `~/.claude/.credentials.json` instead of Keychain
- Timer managed by systemd user units (`~/.config/systemd/user/`)
- Same backup filenames as macOS for compatibility

### JSON Parsing Pattern

All JSON reads use inline `python3 -c "..."` one-liners. There is no jq dependency. `update_config` does in-place field updates via python3.

### Key Functions

| Function | Purpose |
|----------|---------|
| `read_config` | Load all config fields into shell vars |
| `perform_switch` | Atomic credential swap: save current → restore target → update `active_account` |
| `fetch_usage_detailed` | Hit the Claude API; return status + utilization + resets_at + 7-day stats |
| `refresh_backup_token` | Refresh a single account's OAuth token using the refresh endpoint |
| `save_current_credentials` / `restore_credentials` | Keychain↔file backup swap |
| `register_auto_continue` | Store a session ID + reset time in `session-autostart-state.json` |
| `maybe_run_auto_continue_sessions` | Fire `claude --resume` for sessions whose reset time has passed |
| `log` | Append to log; POLL/SKIP lines deduplicated by content within 15 min |

### Log Levels

`POLL`, `SWITCH`, `SKIP`, `WARN`, `TOKEN`, `SESSION`, `CONTINUE`, `TIMER`, `RESUME`, `PAUSE`, `KITTY`, `SYNC`

## Active Merge Conflict

`README.md` currently has an unresolved merge conflict (`UU` status). Resolve it before committing documentation changes.

## Dependencies

- `bash`, `python3`, `python-dateutil` (required)
- `kitty` (optional — for terminal pause/resume)
- `scp`/`ssh` (optional — for cross-machine token sync)
