#!/bin/bash
# Builds build/ClaudePulse.app (menu-bar app, no Dock icon). Pass --run to relaunch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudePulse"
APP="build/ClaudePulse.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudePulse"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Pulse</string>
    <key>CFBundleDisplayName</key><string>Claude Pulse</string>
    <key>CFBundleIdentifier</key><string>local.claude-pulse</string>
    <key>CFBundleExecutable</key><string>ClaudePulse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# macOS ties privacy grants (Accessibility, notifications) to the code signature. An ad-hoc
# signature changes on every build and would drop those grants, so prefer a real identity.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "Signed with identity $IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "Signed ad hoc (privacy grants reset on each build)"
fi
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x ClaudePulse 2>/dev/null || true
    sleep 0.5
    open "$APP"
fi
