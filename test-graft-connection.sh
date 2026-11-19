#!/bin/bash
# Tests the read-only integration and Graft's explicit per-account reset action on a temporary socket.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
python3 "$ROOT/Tests/GraftConnection/evidence.py"
FIXTURE="$(mktemp -d /tmp/ai-graft.XXXXXX)"
server=""
cleanup() {
    if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$FIXTURE"
}
trap cleanup EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos${MACOS_DEPLOYMENT_TARGET:-13.0}" \
    "$ROOT"/Sources/Shared/*.swift "$ROOT/Sources/App/GraftConnection.swift" \
    "$ROOT/Sources/App/ClaudeAccountLabels.swift" "$ROOT/Sources/App/Accessibility.swift" \
    "$ROOT/Tests/GraftConnection/main.swift" -o "$FIXTURE/checks"
python3 "$ROOT/Tests/GraftConnection/fixture.py" "$FIXTURE" &
server=$!
for ((i=0; i<100; i++)); do
    [[ -S "$FIXTURE/pool/relay.sock" ]] && break
    sleep .05
done
"$FIXTURE/checks" "$FIXTURE"
wait "$server"
server=""
