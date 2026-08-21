#!/usr/bin/env bash
#
# Prepare the complete rusty_v8 source used for the iOS Code Mode host. The
# crates.io package deliberately omits large source-build inputs, so an iOS
# build must use the recursively checked-out repository at the matching ref.

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <work-dir>" >&2
    exit 64
fi

work_dir="$1"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../Configuration/upstream.env
source "$repository_root/Configuration/upstream.env"

: "${RUSTY_V8_REPO:?}"
: "${RUSTY_V8_REF:?}"

[[ "$RUSTY_V8_REF" =~ ^[0-9a-f]{40}$ ]] || {
    echo "error: RUSTY_V8_REF must be a full commit sha" >&2
    exit 65
}

stamp_file="$work_dir/.owngoal-rusty-v8-stamp"
if [[ -f "$stamp_file" ]] &&
    [[ "$(cat "$stamp_file")" == "$RUSTY_V8_REF" ]] &&
    [[ "$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)" == "$RUSTY_V8_REF" ]] &&
    ! git -C "$work_dir" submodule status --recursive | grep -qE '^[+-U]'; then
    echo "rusty_v8 is already prepared at $RUSTY_V8_REF"
    exit 0
fi

mkdir -p "$work_dir"
if [[ ! -d "$work_dir/.git" ]]; then
    git -C "$work_dir" init --quiet
    git -C "$work_dir" remote add origin "$RUSTY_V8_REPO"
fi

git -C "$work_dir" remote set-url origin "$RUSTY_V8_REPO"
rm -f "$stamp_file"

echo "fetching $RUSTY_V8_REPO at $RUSTY_V8_REF"
git -C "$work_dir" fetch --quiet --depth 1 --force origin "$RUSTY_V8_REF"
git -C "$work_dir" checkout --quiet --detach FETCH_HEAD
git -C "$work_dir" reset --quiet --hard FETCH_HEAD
git -C "$work_dir" submodule sync --quiet --recursive
git -C "$work_dir" submodule update --init --depth 1 --jobs "${RUSTY_V8_JOBS:-8}"

resolved_ref="$(git -C "$work_dir" rev-parse HEAD)"
[[ "$resolved_ref" == "$RUSTY_V8_REF" ]] || {
    echo "error: expected rusty_v8 $RUSTY_V8_REF, got $resolved_ref" >&2
    exit 65
}
if git -C "$work_dir" submodule status --recursive | grep -qE '^[+-U]'; then
    echo "error: rusty_v8 has missing or mismatched submodules" >&2
    exit 65
fi

printf '%s\n' "$RUSTY_V8_REF" >"$stamp_file"
echo "prepared rusty_v8 $RUSTY_V8_REF"
