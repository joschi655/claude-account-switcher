#!/bin/bash
# Claude Auto-Switch — Install Script
# Sets up a per-user timer on macOS or Linux to run claude-auto-switch.sh every 60 seconds

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-auto-switch.sh"
OS_TYPE="$(uname -s)"
PLIST_TEMPLATE="$SCRIPT_DIR/com.claude.auto-switch.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/com.claude.auto-switch.plist"
SYSTEMD_SERVICE_TEMPLATE="$SCRIPT_DIR/com.claude.auto-switch.service.template"
SYSTEMD_TIMER_TEMPLATE="$SCRIPT_DIR/com.claude.auto-switch.timer.template"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SYSTEMD_SERVICE_DEST="$SYSTEMD_DIR/com.claude.auto-switch.service"
SYSTEMD_TIMER_DEST="$SYSTEMD_DIR/com.claude.auto-switch.timer"
CONFIG="$HOME/.claude/auto-switch-config.json"

echo "=== Claude Auto-Switch Installer ==="
echo ""

# Check requirements
if ! command -v python3 &>/dev/null; then
  if [ "$OS_TYPE" = "Darwin" ]; then
    echo "❌ python3 not found. Install via Homebrew: brew install python3"
  else
    echo "❌ python3 not found. Install python3 first, then rerun this installer."
  fi
  exit 1
fi

if ! python3 -c "import dateutil" 2>/dev/null; then
  echo "⚠️  python-dateutil not found — installing..."
  python3 -m pip install python-dateutil --break-system-packages || python3 -m pip install python-dateutil
fi

# Ensure state directory exists
mkdir -p "$HOME/.claude"

# Make script executable
chmod +x "$SCRIPT"

if [ ! -f "$CONFIG" ]; then
  cp "$SCRIPT_DIR/config.example.json" "$CONFIG"
  echo "Created default config at $CONFIG"
fi

if [ "$OS_TYPE" = "Darwin" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  echo "Installing launchd agent to $PLIST_DEST..."
  sed "s|INSTALL_PATH|$SCRIPT_DIR|" "$PLIST_TEMPLATE" > "$PLIST_DEST"

  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  launchctl load "$PLIST_DEST"

  echo ""
  echo "✅ Installed and started on macOS."
  echo ""
  echo "Next steps:"
  echo "  1. Edit $CONFIG"
  echo "  2. Add your full account labels under 'accounts'"
  echo "  3. Save credentials for each account — see README.md"
  echo "  4. Set 'enabled': true when ready"
  echo ""
  echo "To stop:  launchctl unload $PLIST_DEST"
  echo "To start: launchctl load $PLIST_DEST"
  echo "Log:      tail -f $HOME/.claude/auto-switch.log"
  exit 0
fi

mkdir -p "$SYSTEMD_DIR"
echo "Installing systemd user units to $SYSTEMD_DIR..."
sed "s|INSTALL_PATH|$SCRIPT_DIR|" "$SYSTEMD_SERVICE_TEMPLATE" > "$SYSTEMD_SERVICE_DEST"
cp "$SYSTEMD_TIMER_TEMPLATE" "$SYSTEMD_TIMER_DEST"

if command -v systemctl &>/dev/null; then
  if systemctl --user daemon-reload && systemctl --user enable --now com.claude.auto-switch.timer; then
    echo ""
    echo "✅ Installed and started on Linux (systemd user timer)."
    echo ""
    echo "Next steps:"
    echo "  1. Edit $CONFIG"
    echo "  2. Add your full account labels under 'accounts'"
    echo "  3. Save credentials for each account — see README.md"
    echo "  4. Set 'enabled': true when ready"
    echo ""
    echo "Timer status: systemctl --user status com.claude.auto-switch.timer"
    echo "Service logs: journalctl --user -u com.claude.auto-switch.service -f"
    echo "App log:      tail -f $HOME/.claude/auto-switch.log"
    exit 0
  fi

  echo ""
  echo "⚠️  systemctl exists, but the user timer could not be enabled automatically."
  echo ""
  echo "You can try manually:"
  echo "  systemctl --user daemon-reload"
  echo "  systemctl --user enable --now com.claude.auto-switch.timer"
  echo ""
  echo "Falling back to manual scheduler instructions below."
fi

echo ""
echo "⚠️  systemctl not found. Installed config and systemd templates, but did not start a timer."
echo ""
echo "Next steps:"
echo "  1. Edit $CONFIG"
echo "  2. Add your full account labels under 'accounts'"
echo "  3. Save credentials for each account — see README.md"
echo "  4. Run the script from cron or another scheduler every minute"
echo ""
echo "Cron example: * * * * * /bin/bash $SCRIPT >/dev/null 2>&1"
echo "Log:          tail -f $HOME/.claude/auto-switch.log"
