#!/usr/bin/env bash
#
# Fail if a Codex staging tree, payload, or shipped system config would install
# extra skill trees. Used by make check and Scripts/package-deb.sh.

set -Eeuo pipefail

usage() {
    echo "usage: $0 --config <system-config.toml> [--tree <staging-root>] [--payload <payload-dir>]" >&2
    echo "       $0 --self-test" >&2
    exit 64
}

toml_section_key_equals() {
    local file="$1" section="$2" key="$3" expected="$4"
    awk -v section="$section" -v key="$key" -v expected="$expected" '
        /^\[/ { in_section = ($0 == "[" section "]") }
        in_section {
            line = $0
            sub(/[ \t]*#.*$/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == key " = " expected) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}

check_config() {
    local file="$1"
    [[ -f "$file" ]] || {
        echo "error: missing system config: $file" >&2
        return 65
    }
    toml_section_key_equals "$file" "skills.bundled" "enabled" "false" || {
        echo "error: $file must set [skills.bundled] enabled = false so sample system skills are not extracted at startup" >&2
        return 65
    }
}

check_tree() {
    local root="$1"
    [[ -d "$root" ]] || {
        echo "error: missing staging tree: $root" >&2
        return 65
    }
    local matches
    matches="$(find "$root" -name SKILL.md -print)"
    if [[ -n "$matches" ]]; then
        echo "error: extra skill trees (SKILL.md) under $root:" >&2
        printf '%s\n' "$matches" | sed 's/^/       /' >&2
        return 65
    fi
}

check_payload() {
    local payload="$1"
    [[ -d "$payload" ]] || {
        echo "error: missing payload directory: $payload" >&2
        return 65
    }
    if [[ -d "$payload/skills" ]]; then
        echo "error: payload has a skills directory: $payload/skills" >&2
        return 65
    fi
    check_tree "$payload"
}

self_test() {
    local scratch
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/codex-skill-policy.XXXXXX")"
    trap 'rm -rf -- "$scratch"' RETURN

    local ok_config="$scratch/ok.toml"
    cat >"$ok_config" <<'EOF'
[features]
remote_plugin = false

[skills.bundled]
enabled = false
EOF
    check_config "$ok_config"

    local bad_config="$scratch/bad.toml"
    printf '%s\n' '[skills.bundled]' 'enabled = true' >"$bad_config"
    check_config "$bad_config" 2>/dev/null && {
        echo "error: self-test expected a config with bundled skills enabled to fail" >&2
        return 65
    }

    local empty="$scratch/empty"
    mkdir -p "$empty"
    check_tree "$empty"
    check_payload "$empty"

    local with_skill="$scratch/with-skill"
    mkdir -p "$with_skill/usr/libexec/codex/sample"
    printf '%s\n' '# extra' >"$with_skill/usr/libexec/codex/sample/SKILL.md"
    check_tree "$with_skill" 2>/dev/null && {
        echo "error: self-test expected SKILL.md in the staging tree to fail" >&2
        return 65
    }

    local with_payload_skills="$scratch/payload"
    mkdir -p "$with_payload_skills/skills"
    check_payload "$with_payload_skills" 2>/dev/null && {
        echo "error: self-test expected a payload skills directory to fail" >&2
        return 65
    }

    echo "skill policy self-test ok"
}

config=""
tree=""
payload=""
run_self_test=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --config)
        [[ "$#" -ge 2 ]] || usage
        config="$2"
        shift 2
        ;;
    --tree)
        [[ "$#" -ge 2 ]] || usage
        tree="$2"
        shift 2
        ;;
    --payload)
        [[ "$#" -ge 2 ]] || usage
        payload="$2"
        shift 2
        ;;
    --self-test)
        run_self_test=1
        shift
        ;;
    *)
        usage
        ;;
    esac
done

if ((run_self_test)); then
    self_test
    [[ -n "$config" ]] && check_config "$config"
    exit 0
fi

[[ -n "$config" ]] || usage
check_config "$config"
[[ -n "$tree" ]] && check_tree "$tree"
[[ -n "$payload" ]] && check_payload "$payload"
