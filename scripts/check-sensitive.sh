#!/usr/bin/env bash
#
# Refuse to publish anything that carries sensitive information.
#
#   scripts/check-sensitive.sh                 # every git-tracked file
#   scripts/check-sensitive.sh <dir-or-file>…  # a staging tree, a payload, a .deb
#
# Looks for credentials, private keys, personal home paths, device identifiers,
# non-loopback IP addresses and e-mail addresses outside the project's public
# maintainer domain. Binary files and .deb payloads are scanned through
# `strings`, so a build path baked into an executable is caught too.
#
# Exit 0 when clean, 65 with every hit listed otherwise.

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# One extended regex per class. Keep them specific: a false positive blocks a
# release, a false negative leaks. Add an allowlist entry, never loosen a rule.
patterns=(
    'gh[pousr]_[A-Za-z0-9]{20,}'                       # GitHub tokens
    'github_pat_[A-Za-z0-9_]{20,}'
    'AKIA[0-9A-Z]{16}'                                 # AWS access key id
    'xox[abprs]-[A-Za-z0-9-]{10,}'                     # Slack tokens
    'sk-[A-Za-z0-9]{20,}'                              # OpenAI-style API keys
    'BEGIN [A-Z ]*PRIVATE KEY'
    '(password|passwd|secret|token)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"']{4,}' # literal secrets
    '/(Users|home)/[A-Za-z0-9._-]+'                    # personal home paths
    '/private/tmp/[A-Za-z0-9._-]+'                     # build scratch paths
    '[0-9A-F]{8}-[0-9A-F]{16}'                         # iOS device UDIDs
    '[0-9]{1,3}(\.[0-9]{1,3}){3}'                      # IPv4 addresses
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'   # e-mail addresses
)

# Matches that are public by design.
allow=(
    '127\.0\.0\.1'
    '0\.0\.0\.0'
    '255\.255\.255\.255'
    '@owngoal\.dev'
    'noreply@anthropic\.com'
    'noreply@github\.com'
    '/Users/[[:space:]]*$'                             # doc prose naming the directory itself
    'TARGET_DIR_HOME.*/Users'
    '\$\{?(HOME|DEVICE_[A-Z_]+|DEVICE_SUDO_PASSWORD)'  # variable names, not values
    'DEVICE_SUDO_PASSWORD'
    'sudo_password'
    'version-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'           # dotted version numbers, not IPs
    'compatibility version'
)

pattern_regex="$(IFS='|'; echo "${patterns[*]}")"
allow_regex="$(IFS='|'; echo "${allow[*]}")"

scan_text() { # <label> <file>
    local label="$1" file="$2" hits
    hits="$(grep -nEa -- "$pattern_regex" "$file" | grep -Ev -- "$allow_regex" || true)"
    [[ -z "$hits" ]] || printf '%s\n' "$hits" | sed "s|^|$label:|"
}

scan_binary() { # <label> <file>
    local label="$1" file="$2" hits
    hits="$(strings -a -- "$file" | grep -Ea -- "$pattern_regex" | grep -Ev -- "$allow_regex" || true)"
    [[ -z "$hits" ]] || printf '%s\n' "$hits" | sed "s|^|$label: (binary) |"
}

scan_file() { # <file>
    local file="$1"
    case "$file" in
    *.deb)
        local extracted
        extracted="$(mktemp -d "${TMPDIR:-/tmp}/sensitive-deb.XXXXXX")"
        dpkg-deb --raw-extract "$file" "$extracted/tree" 2>/dev/null || dpkg-deb -R "$file" "$extracted/tree"
        scan_tree "$extracted/tree" | sed "s|$extracted/tree|$file|"
        rm -rf -- "$extracted"
        ;;
    *)
        if file -b --mime-encoding -- "$file" | grep -q binary; then
            scan_binary "$file" "$file"
        else
            scan_text "$file" "$file"
        fi
        ;;
    esac
}

scan_tree() { # <dir>
    local file
    while IFS= read -r -d '' file; do
        scan_file "$file"
    done < <(find "$1" -name .git -prune -o -type f ! -name .DS_Store -print0)
}

findings=""
if [[ "$#" -eq 0 ]]; then
    while IFS= read -r -d '' file; do
        [[ -f "$repository_root/$file" && ! -L "$repository_root/$file" ]] || continue
        # vendor/ holds pinned third-party source that is already public on
        # crates.io; its test fixtures are upstream's, not ours.
        [[ "$file" != vendor/* ]] || continue
        findings+="$(scan_file "$repository_root/$file")"$'\n'
    done < <(git -C "$repository_root" ls-files -z)
else
    for target in "$@"; do
        [[ -e "$target" ]] || { echo "error: no such file or directory: $target" >&2; exit 66; }
        if [[ -d "$target" ]]; then
            findings+="$(scan_tree "$target")"$'\n'
        else
            findings+="$(scan_file "$target")"$'\n'
        fi
    done
fi

findings="$(printf '%s' "$findings" | sed '/^$/d')"
if [[ -n "$findings" ]]; then
    echo "error: sensitive information found; not publishing:" >&2
    sed 's/^/       /' <<<"$findings" >&2
    echo "       (add a deliberate public value to the allowlist in scripts/check-sensitive.sh)" >&2
    exit 65
fi
echo "sensitive-information review: clean"
