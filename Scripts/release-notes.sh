#!/usr/bin/env bash
#
# Render Packaging/release-notes.md for one tag, on stdout.

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <tag>" >&2
    exit 64
fi

tag="$1"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
template="$repository_root/Packaging/release-notes.md"

# shellcheck source=../Configuration/upstream.env
source "$repository_root/Configuration/upstream.env"

: "${UPSTREAM_REF:?}"
: "${MIN_IOS:?}"

[[ -f "$template" ]] || { echo "error: missing $template" >&2; exit 66; }

version="$(cat "$repository_root/Configuration/version.txt")"
version="${version//[[:space:]]/}"
package_id="${PACKAGE_ID:-wiki.qaq.codex}"

rendered="$(
    sed \
        -e "s|@PACKAGE_ID@|$package_id|g" \
        -e "s|@VERSION@|$version|g" \
        -e "s|@TAG@|$tag|g" \
        -e "s|@UPSTREAM_REF@|$UPSTREAM_REF|g" \
        -e "s|@UPSTREAM_SHORT@|${UPSTREAM_REF:0:7}|g" \
        -e "s|@MIN_IOS_MAJOR@|${MIN_IOS%%.*}|g" \
        "$template"
)"

if grep -q '@[A-Z_]*@' <<<"$rendered"; then
    echo "error: release notes still hold unsubstituted placeholders:" >&2
    grep -n '@[A-Z_]*@' <<<"$rendered" | sed 's/^/       /' >&2
    exit 65
fi

printf '%s\n' "$rendered"
