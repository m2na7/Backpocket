#!/bin/bash
# Fails when the four Localizable.strings files disagree on which keys exist.
#
# A key missing from one .lproj does not fail the build and does not fall back
# to English: SwiftUI renders the raw identifier, so `footer.items %lld` ships
# to Korean users as the literal string "footer.items %lld". Nothing else in
# the repo catches that, which is why this runs in CI and in `make lint`.
#
# Duplicates are caught too — the last definition silently wins, so a
# re-added key quietly shadows the translated one.
set -euo pipefail
cd "$(dirname "$0")/.."

REFERENCE="en"
LANGS=(en ko ja zh-Hans)
status=0

keys_of() {
    # Keys are the leading quoted token of a `"key" = "value";` line. Anything
    # else (comments, blanks) has no leading quote and is skipped.
    sed -n 's/^"\([^"]*\)".*/\1/p' "Resources/$1.lproj/Localizable.strings" | sort
}

for lang in "${LANGS[@]}"; do
    file="Resources/$lang.lproj/Localizable.strings"
    if [ ! -f "$file" ]; then
        echo "$file: missing"
        status=1
        continue
    fi
    dupes="$(keys_of "$lang" | uniq -d)"
    if [ -n "$dupes" ]; then
        echo "$file: duplicate keys (the last one wins, silently):"
        echo "$dupes" | sed 's/^/  /'
        status=1
    fi
done
[ "$status" -eq 0 ] || exit "$status"

reference_keys="$(keys_of "$REFERENCE" | uniq)"
for lang in "${LANGS[@]}"; do
    [ "$lang" = "$REFERENCE" ] && continue
    lang_keys="$(keys_of "$lang" | uniq)"

    missing="$(comm -23 <(echo "$reference_keys") <(echo "$lang_keys"))"
    extra="$(comm -13 <(echo "$reference_keys") <(echo "$lang_keys"))"

    if [ -n "$missing" ]; then
        echo "Resources/$lang.lproj/Localizable.strings: missing keys present in $REFERENCE:"
        echo "$missing" | sed 's/^/  /'
        status=1
    fi
    if [ -n "$extra" ]; then
        echo "Resources/$lang.lproj/Localizable.strings: keys absent from $REFERENCE:"
        echo "$extra" | sed 's/^/  /'
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "Localization: $(echo "$reference_keys" | wc -l | tr -d ' ') keys, identical across ${LANGS[*]}."
fi
exit "$status"
