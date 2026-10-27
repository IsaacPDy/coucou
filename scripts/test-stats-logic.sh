#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-stats-logic.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/RecapStore.swift NotchBuddy/Sources/App/StatsLogic.swift \
    tests/StatsLogicTests.swift -o "$TEST_DIR/stats-logic-tests"
"$TEST_DIR/stats-logic-tests"
