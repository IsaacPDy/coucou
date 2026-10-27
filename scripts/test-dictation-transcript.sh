#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-dictation-transcript.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/DictationTranscript.swift \
    tests/DictationTranscriptTests.swift -o "$TEST_DIR/dictation-transcript-tests"
"$TEST_DIR/dictation-transcript-tests"
