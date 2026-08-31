#!/bin/bash
# Mutation testing: change one operator in a source file, run the suite, and
# see whether anything fails. A mutation that SURVIVES means the tests execute
# that line without asserting on what it produces.
#
# This exists because coverage lies about exactly that. ItemRow.swift once
# measured 94% of lines and caught none of its five mutations: the render
# smoke tests ran it, so the number rose, while nothing checked the result.
# The row's `==` — what SwiftUI consults to decide whether to redraw — could
# have every `&&` flipped to `||` untouched. Coverage cannot see that and
# this can.
#
#   ./scripts/mutants.sh                       a default sample of Sources
#   ./scripts/mutants.sh Sources/.../Foo.swift one or more specific files
#   MUTANTS_ALL=1 ./scripts/mutants.sh         every site in every source file
#
# Slow by nature: every mutation is a build plus a full test run, so budget
# tens of seconds each. The default samples two sites per operator per file
# and is what you run on the files a change touches — a smell detector, not a
# score. `MUTANTS_ALL=1` drops that cap and walks the whole tree, which takes
# hours and is how you get a survivor list that is complete rather than
# sampled.
#
# Do not try to split that pass across parallel checkouts. Two copies of the
# suite fail each other — the language tests write the process-wide
# AppleLanguages domain — so every mutation looks caught and the pass reports
# 100% off a red baseline, the worst output this tool can produce.
#
# A surviving mutant is not automatically a gap — an EQUIVALENT mutant changes
# no behaviour and no test can ever kill it. Read the survivor before writing
# anything: a test that pins an equivalent mutant is a test asserting an
# implementation detail.
set -uo pipefail
cd "$(dirname "$0")/.."

# Mutations are written into the working tree and reverted with `git
# checkout`. Refusing to start dirty is what keeps that from eating real
# edits, and the trap is what keeps a crash from leaving one behind.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "mutants: working tree is dirty — commit or stash first." >&2
  echo "         mutations are reverted with 'git checkout', which would" >&2
  echo "         discard your changes along with them." >&2
  exit 1
fi
trap 'git checkout -- Sources/ 2>/dev/null || true' EXIT INT TERM

if [ "$#" -gt 0 ]; then
  FILES=("$@")
elif [ -n "${MUTANTS_ALL:-}" ]; then
  IFS=$'\n' read -r -d '' -a FILES < <(find Sources -name '*.swift' | sort && printf '\0')
else
  # A default sample: the pure decision types, where a survivor is always a
  # real gap, plus the two files whose caps have historically been tested
  # only well inside their range.
  FILES=(
    Sources/BackpocketKit/Panel/PanelKeyboard.swift
    Sources/BackpocketKit/Panel/PanelSelection.swift
    Sources/BackpocketKit/Panel/PanelLists.swift
    Sources/BackpocketKit/Panel/BoundedCache.swift
    Sources/BackpocketKit/Panel/ItemRow.swift
    Sources/BackpocketKit/Storage/Store.swift
    Sources/BackpocketKit/Clipboard/ClipboardWatcher.swift
  )
fi

# Two per operator by default, every one under MUTANTS_ALL.
LIMIT=2
[ -n "${MUTANTS_ALL:-}" ] && LIMIT=100000

caught=0
survived=0
skipped=0
SURVIVORS=()

# Line numbers where a pattern appears in real code. Comment lines are
# dropped: mutating prose costs a full build to learn nothing.
sites() {  # file, grep pattern
  grep -n -- "$2" "$1" | grep -v '^[0-9]*: *//' | cut -d: -f1 | head -"$LIMIT"
}

# A mutation is not obliged to make the suite finish. Flipping the `==` that
# ends a scanner's inner loop leaves it running forever, and an unbounded
# `swift test` stops the whole pass dead — the exhaustive run hit exactly that
# in SyntaxHighlighter and sat there until it was killed by hand. A suite that
# never returns has not passed, so a timeout counts as caught.
TEST_TIMEOUT=${MUTANTS_TEST_TIMEOUT:-120}

run_tests() {
  swift test >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$TEST_TIMEOUT" ]; then
      kill -9 "$pid" 2>/dev/null
      # The helper process outlives its parent, and a stray one holds the
      # build directory against the next mutation.
      pkill -9 -f "$PWD/.build" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

try() {  # file, line, sed expression, label
  local file="$1" line="$2" expr="$3" label="$4"
  sed -i '' "${line}${expr}" "$file" 2>/dev/null || { skipped=$((skipped + 1)); return; }

  if git diff --quiet -- "$file"; then
    skipped=$((skipped + 1))                       # the pattern matched nothing
  elif ! swift build --build-tests >/dev/null 2>&1; then
    skipped=$((skipped + 1))                       # the mutation did not compile
  elif run_tests; then
    survived=$((survived + 1))
    SURVIVORS+=("$file:$line  $label")
    echo "  SURVIVED  $file:$line  $label"
  else
    caught=$((caught + 1))
    echo "  caught    $file:$line  $label"
  fi
  git checkout -- "$file"
}

for file in "${FILES[@]}"; do
  [ -f "$file" ] || { echo "mutants: no such file: $file" >&2; exit 1; }
  echo "$file"
  # Boundaries first: nearly every survivor found so far has been a cap
  # exercised well inside its range and never at the edge.
  for ln in $(sites "$file" ' >= '); do try "$file" "$ln" 's| >= | > |' '>= became >'; done
  for ln in $(sites "$file" ' <= '); do try "$file" "$ln" 's| <= | < |' '<= became <'; done
  for ln in $(sites "$file" ' && '); do try "$file" "$ln" 's| \&\& | \|\| |' '&& became ||'; done
  for ln in $(sites "$file" 'guard !'); do
    try "$file" "$ln" 's|guard !|guard |' 'dropped a ! in a guard'
  done
  # Equality is the bulk of the tree's decisions, and the cheapest thing to
  # get subtly wrong in a filter or a dedupe.
  for ln in $(sites "$file" ' == '); do try "$file" "$ln" 's| == | != |' '== became !='; done
  for ln in $(sites "$file" ' != '); do try "$file" "$ln" 's| != | == |' '!= became =='; done
  # Off-by-one in arithmetic, and a constant answer where a decision belongs.
  for ln in $(sites "$file" ' + '); do try "$file" "$ln" 's| + | - |' '+ became -'; done
  for ln in $(sites "$file" ' - '); do try "$file" "$ln" 's| - | + |' '- became +'; done
  for ln in $(sites "$file" 'return true'); do
    try "$file" "$ln" 's|return true|return false|' 'return true became false'
  done
  for ln in $(sites "$file" 'return false'); do
    try "$file" "$ln" 's|return false|return true|' 'return false became true'
  done
done

echo
echo "caught:   $caught"
echo "survived: $survived"
echo "skipped:  $skipped  (did not compile, or the pattern matched nothing)"
[ "$((caught + survived))" -gt 0 ] &&
  echo "score:    $((caught * 100 / (caught + survived)))%"

if [ "${#SURVIVORS[@]}" -gt 0 ]; then
  echo
  echo "survivors — executed but not asserted on:"
  printf '  %s\n' "${SURVIVORS[@]}"
fi

# Loud, because a mutation left in the tree would be far worse than a wrong
# score, and the trap above cannot report on itself.
if git diff --quiet -- Sources/; then
  echo
  echo "tree restored."
else
  echo
  echo "mutants: SOURCES ARE STILL MODIFIED — run 'git checkout -- Sources/'" >&2
  exit 1
fi
