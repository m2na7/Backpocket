#!/bin/bash
# Line coverage per source file, worst first.
#
# Reported, never gated. The number is low by construction and saying so is
# the point: this project verifies extracted value types with unit tests and
# SwiftUI views with screenshots, so the views read as 0% and always will
# until someone decides to take on a rendering-test dependency. A threshold
# here would either be set so low it means nothing or would push contributors
# toward tests that assert a view was constructed.
#
# What it IS for: seeing a file slide. A value type that was near 100% and is
# now half-covered has grown logic nobody tested, which is the regression this
# catches and no other tool in the repo does.
#
#   ./scripts/coverage.sh            per-file table, worst first
#   ./scripts/coverage.sh --total    one line, for a CI summary
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)-apple-macosx"
PROFDATA=".build/$ARCH/debug/codecov/default.profdata"
BUNDLE=".build/$ARCH/debug/BackpocketPackageTests.xctest"
BINARY="$BUNDLE/Contents/MacOS/BackpocketPackageTests"

swift test --enable-code-coverage >/dev/null 2>&1 || {
  echo "coverage: tests failed; run 'swift test' to see why" >&2
  exit 1
}

if [ ! -f "$PROFDATA" ] || [ ! -f "$BINARY" ]; then
  echo "coverage: no profile data at $PROFDATA" >&2
  exit 1
fi

# Tests and dependencies are not the subject; only shipped sources are.
report() {
  xcrun llvm-cov report "$BINARY" \
    -instr-profile="$PROFDATA" \
    -ignore-filename-regex='\.build|Tests/' "$@"
}

if [ "${1:-}" = "--total" ]; then
  report | awk '/^TOTAL/ { print "Coverage: " $10 " of lines (" $4 " of regions)" }'
  exit 0
fi

# Columns: 1 file, 8 lines, 9 missed, 10 cover.
report | awk '
  /^Filename|^-{5,}/ { next }
  /^TOTAL/ { total = $0; next }
  NF > 8 { printf "%7s  %6s lines  %s\n", $10, $8, $1 }
' | sort -n

report | awk '/^TOTAL/ { printf "\n%7s  %6s lines  TOTAL\n", $10, $8 }'
