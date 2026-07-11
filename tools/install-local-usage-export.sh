#!/bin/sh
# Install the local usage exporter (Opencode, Claude Code, Codex) as a
# LaunchAgent that runs every 5 minutes.
# The script is copied to Application Support because launchd cannot read
# TCC-protected folders such as Documents. Re-run after editing the exporter.
set -eu

SOURCE="$(cd "$(dirname "$0")" && pwd)/export-local-usage.py"
TARGET="$HOME/Library/Application Support/LimitBar/export-local-usage.py"
PLIST="$HOME/Library/LaunchAgents/com.limitbar.usage-export.plist"
LOG_DIR="$HOME/Library/Logs/LimitBar"

mkdir -p "$HOME/Library/Application Support/LimitBar" "$HOME/Library/LaunchAgents" "$LOG_DIR"
cp "$SOURCE" "$TARGET"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.limitbar.usage-export</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$TARGET</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/usage-export.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/usage-export.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/com.limitbar.usage-export" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Exporter runs every 5 minutes; log: $LOG_DIR/usage-export.log"
echo "Uninstall with: launchctl bootout gui/\$(id -u)/com.limitbar.usage-export && rm '$PLIST'"
