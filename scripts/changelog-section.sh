#!/bin/bash
# Prints one version's entry from CHANGELOG.md, for use as a release body.
#
#   ./scripts/changelog-section.sh 0.1.3
#
# Release notes and the changelog are the same text written twice otherwise,
# and the copy nobody reads while cutting a release is the one that drifts.
# GitHub's --generate-notes cannot stand in: it summarises merged pull
# requests, and a project developed without them produces an empty body.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: changelog-section.sh <version>" >&2; exit 1; }

# Everything between this version's heading and the next one, blank lines at
# either end trimmed. The ones in between are Markdown, not padding: they
# separate paragraphs and end lists, so they are held back and written out
# only once another line follows. Exits non-zero when the section is missing
# so a release stops rather than shipping an empty body.
SECTION="$(awk -v version="## [$VERSION]" '
    index($0, version) == 1 { found = 1; next }
    found && /^## \[/       { exit }
    found                   { print }
' CHANGELOG.md | awk '
    !NF  { blank++; next }
    seen { while (blank > 0) { print ""; blank-- } }
         { blank = 0; seen = 1; print }
')"

if [ -z "$SECTION" ]; then
  echo "changelog-section.sh: CHANGELOG.md has no entry for $VERSION" >&2
  exit 1
fi

printf '%s\n' "$SECTION"
