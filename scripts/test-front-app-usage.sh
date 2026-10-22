#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-front-app-usage.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/FrontAppUsageLogic.swift \
    tests/FrontAppUsageTests.swift -o "$TEST_DIR/front-app-usage-tests"
"$TEST_DIR/front-app-usage-tests"
