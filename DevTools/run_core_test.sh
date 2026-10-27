#!/usr/bin/env bash
# Compiles the platform-independent protocol core with the test driver and runs it
# against the mock PiKVM server. Needs `swiftc` (Linux or macOS) and python3.
set -euo pipefail
cd "$(dirname "$0")"
build="${TMPDIR:-/tmp}/kvmremote-core-test"
mkdir -p "$build"

swiftc -O -o "$build/coretest" ../KVMRemote/Core/*.swift CoreTest/main.swift

python3 mock_pikvm.py --port 5901 > "$build/server.log" &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
sleep 0.5

"$build/coretest" 5901 admin
"$build/coretest" 5901 wrong
sleep 0.3

echo "--- messages seen by the mock server ---"
cat "$build/server.log"
python3 check_server_log.py "$build/server.log"
