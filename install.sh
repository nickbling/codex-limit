#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mode=${1:-}
case "$mode" in
    ''|--check|--minute|--hardware) ;;
    *) echo 'Usage: ./install.sh [--check|--minute|--hardware]' >&2; exit 1 ;;
esac
if [[ -z "$mode" ]] && ! command -v codex >/dev/null; then
    echo 'Install Codex CLI and run codex login first.' >&2
    exit 1
fi
app="${APP_DIR:-$HOME/Applications}/Codex Limit.app"
if [[ -z "${APP_DIR:-}" && -d '/Applications/Codex Limit.app' ]]; then app='/Applications/Codex Limit.app'; fi
saver="$HOME/Library/Screen Savers/Codex Limit.saver"
agent="$HOME/Library/LaunchAgents/local.codex-limit.plist"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

mkdir -p "$build/Codex Limit.app/Contents/MacOS" "$build/Codex Limit.saver/Contents/MacOS"
xcrun swiftc -swift-version 6 -parse-as-library CodexLimit.swift UsageSnapshot.swift CodexSaver.swift LockScreenOverlay.swift QuietDisplay.swift \
    -framework AppKit -framework ScreenSaver -framework IOKit -o "$build/Codex Limit.app/Contents/MacOS/CodexLimit"
cp App-Info.plist "$build/Codex Limit.app/Contents/Info.plist"
plutil -insert CodexPath -string "$PATH" "$build/Codex Limit.app/Contents/Info.plist"
codesign --force --sign - "$build/Codex Limit.app"
xcrun swiftc -swift-version 6 -emit-library CodexSaver.swift UsageSnapshot.swift \
    -framework ScreenSaver -framework AppKit -o "$build/Codex Limit.saver/Contents/MacOS/CodexSaver"
cp Saver-Info.plist "$build/Codex Limit.saver/Contents/Info.plist"
codesign --force --sign - "$build/Codex Limit.saver"
xcrun swiftc -swift-version 6 -parse-as-library Checks.swift UsageSnapshot.swift QuietDisplay.swift \
    -framework AppKit -framework ScreenSaver -framework IOKit -o "$build/checks"
"$build/Codex Limit.app/Contents/MacOS/CodexLimit" --test
"$build/checks" "$build/Codex Limit.saver" "$build/preview.png" "$mode"
if [[ "$mode" == --hardware ]]; then "$build/checks" --hardware; fi
if [[ -n "$mode" ]]; then exit 0; fi

plutil -create xml1 "$build/agent.plist"
plutil -insert Label -string local.codex-limit "$build/agent.plist"
plutil -insert ProgramArguments -json '[]' "$build/agent.plist"
plutil -insert ProgramArguments.0 -string "$app/Contents/MacOS/CodexLimit" "$build/agent.plist"
plutil -insert RunAtLoad -bool true "$build/agent.plist"
plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "$build/agent.plist"

# Let the running app restore brightness before replacing it or its login agent.
if pgrep -x CodexLimit >/dev/null; then osascript -e 'tell application id "local.codex-limit" to quit'; fi
launchctl bootout "gui/$UID/local.codex-limit" 2>/dev/null || true
mkdir -p "$(dirname "$app")" "$(dirname "$saver")" "$(dirname "$agent")"
ditto "$build/Codex Limit.app" "$app"
killall -u "$USER" legacyScreenSaver 2>/dev/null || true
ditto "$build/Codex Limit.saver" "$saver"
cp "$build/agent.plist" "$agent"
launchctl bootstrap "gui/$UID" "$agent"
echo "Installed: $app"
