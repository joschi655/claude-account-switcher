#!/bin/bash
# Claude Auto-Switch — Install Script
# Sets up launchd agent to run claude-auto-switch.sh every 60 seconds

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-auto-switch.sh"
PLIST_TEMPLATE="$SCRIPT_DIR/com.claude.auto-switch.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/com.claude.auto-switch.plist"
CONFIG="$HOME/.claude/auto-switch-config.json"

echo "=== Claude Auto-Switch Installer ==="
echo ""

# Check requirements
if ! command -v python3 &>/dev/null; then
  echo "❌ python3 not found. Install via Homebrew: brew install python3"
  exit 1
fi

if ! python3 -c "import dateutil" 2>/dev/null; then
  echo "⚠️  python-dateutil not found — installing..."
  pip3 install python-dateutil --break-system-packages || pip3 install python-dateutil
fi

# Make script executable
chmod +x "$SCRIPT"

# Install launchd plist
echo "Installing launchd agent to $PLIST_DEST..."
sed "s|INSTALL_PATH|$SCRIPT|" "$PLIST_TEMPLATE" > "$PLIST_DEST"

# Load it
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo ""
echo "✅ Installed and started."
echo ""
echo "Next steps:"
echo "  1. Copy config.example.json → $CONFIG"
echo "  2. Edit $CONFIG:"
echo "     - Set your account email patterns under 'accounts'"
echo "     - Set 'enabled': true when ready"
echo "  3. Save credentials for each account — see README.md for instructions"
echo ""
echo "To stop:  launchctl unload $PLIST_DEST"
echo "To start: launchctl load $PLIST_DEST"
echo "Log:      tail -f $HOME/.claude/auto-switch.log"
