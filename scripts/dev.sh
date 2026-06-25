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

APP_BUNDLE="$ROOT/.build/Venice Video Editor.app"

if ! $stream; then
    open "$APP_BUNDLE"
    exit 0
fi

echo "Streaming OSLog (subsystem=io.palmier.pro). Ctrl-C to quit app and stop." >&2
echo >&2

cleanup() {
    pid=$(pgrep -f "Venice Video Editor.app/Contents/MacOS/VeniceVideoEditor" | head -1 || true)
    if [ -n "$pid" ]; then
        osascript -e 'quit app "Venice Video Editor"' 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

( sleep 0.5 && open "$APP_BUNDLE" ) &
log stream \
    --predicate 'subsystem == "io.palmier.pro"' \
    --level info \
    --style compact
