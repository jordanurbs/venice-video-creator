#!/bin/bash
# scripts/dev.sh — build the debug bundle, launch it, and stream its OSLog.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

stream=true
for arg in "$@"; do
    case "$arg" in
        --no-stream) stream=false ;;
    esac
done

"$ROOT/scripts/bundle.sh" debug --fast

APP_BUNDLE="$ROOT/.build/Venice Video Creator.app"

if ! $stream; then
    open "$APP_BUNDLE"
    exit 0
fi

echo "Streaming OSLog (subsystem=ai.venice.videocreator). Ctrl-C to quit app and stop." >&2
echo >&2

cleanup() {
    pid=$(pgrep -f "Venice Video Creator.app/Contents/MacOS/VeniceVideoCreator" | head -1 || true)
    if [ -n "$pid" ]; then
        osascript -e 'quit app "Venice Video Creator"' 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

( sleep 0.5 && open "$APP_BUNDLE" ) &
log stream \
    --predicate 'subsystem == "io.palmier.pro"' \
    --level info \
    --style compact
