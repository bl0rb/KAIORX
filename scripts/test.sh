#!/bin/sh
# Runs the KAIORXKit tests. With only the Command Line Tools installed, Swift Testing needs its
# macro plugin path passed explicitly; with Xcode, plain `swift test` works.
set -eu
cd "$(dirname "$0")/../Packages/KAIORXKit"

PLUGIN_DIR=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ -z "${DEVELOPER_DIR:-}" ] && xcode-select -p 2>/dev/null | grep -q CommandLineTools && [ -d "$PLUGIN_DIR" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
fi
exec swift test "$@"
