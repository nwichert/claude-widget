#!/bin/bash
# Makes Claude Pulse start by itself: at login, and whenever Claude Desktop is opened.
#
#   tools/install-autostart.sh             install (or update) the launcher
#   tools/install-autostart.sh --uninstall remove it
#
# It installs a per-user launchd agent that runs a small check every 20 seconds:
#   - first check after login: start Claude Pulse;
#   - Claude Desktop running and Claude Pulse not: start Claude Pulse;
#   - unless you quit Claude Pulse from its menu, which keeps it closed until Claude Desktop
#     is next opened.
# Nothing here needs administrator rights, and nothing is installed outside your home folder.
set -euo pipefail

LABEL="local.claude-pulse.launcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/ClaudePulse"
CHECK="$SUPPORT/autostart-check.sh"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$PLIST" "$CHECK" "$SUPPORT/quit-by-user"
    echo "Auto-start removed."
    exit 0
fi

if [[ ! -d "$HOME/Applications/ClaudePulse.app" ]]; then
    echo "Install the app first: ./build.sh --run" >&2
    exit 1
fi

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents"

cat > "$CHECK" <<'CHECK'
#!/bin/sh
APP="$HOME/Applications/ClaudePulse.app"
MARK="$HOME/Library/Application Support/ClaudePulse/quit-by-user"
SINCE_LOGIN="/tmp/claude-pulse-started-$(id -u)"   # /tmp is emptied at restart

[ -d "$APP" ] || exit 0
running() { ps -axo comm | grep -q "$1"; }

if running "/ClaudePulse.app/Contents/MacOS/ClaudePulse$"; then
    touch "$SINCE_LOGIN"
    exit 0
fi

# First check since the computer started: open it, whatever happened last time.
if [ ! -e "$SINCE_LOGIN" ]; then
    touch "$SINCE_LOGIN"
    rm -f "$MARK"
    open -g "$APP"
    exit 0
fi

# The capital C matters: Claude Code's own processes are a lowercase "claude".
if running "/Claude.app/Contents/MacOS/Claude$"; then
    [ -e "$MARK" ] || open -g "$APP"
else
    # Claude Desktop is closed, so a menu quit has done its job; next time Claude opens, start again.
    rm -f "$MARK"
fi
CHECK
chmod +x "$CHECK"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>$CHECK</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>20</integer>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Auto-start installed. Claude Pulse will open at login and whenever Claude Desktop opens."
