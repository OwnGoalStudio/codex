#!/usr/bin/env bash
#
# Stage, ad-hoc sign, and build one .deb from a payload directory that
# build-ios.sh assembled. Called once per bootstrap layout; the payload is the
# same both times, only the install prefix and the architecture label differ.

set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: $0 <payload-dir> <output-deb> <version> <architecture> <install-prefix>" >&2
    echo "note: install-prefix is empty for roothide and /var/jb for rootless" >&2
    exit 64
fi

payload="$1"
output_deb="$2"
version="$3"
architecture="$4"
install_prefix="$5"

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"

: "${PROGRAM:?}"
: "${MIN_IOS:?}"
: "${UPSTREAM_REF:?}"
: "${CARGO_BIN:?}"
: "${CODE_MODE_HOST_BIN:?}"

package_id="${PACKAGE_ID:-wiki.qaq.codex}"
control_template="$repository_root/packaging/DEBIAN/control"
entitlements="$repository_root/packaging/${PROGRAM}.entitlements"
launcher_source="$repository_root/packaging/${PROGRAM}.launcher.c"
system_config="$repository_root/packaging/etc/codex/config.toml"
skill_policy_check="$repository_root/scripts/check-skill-policy.sh"

for input in "$control_template" "$entitlements" "$launcher_source" "$system_config" "$skill_policy_check"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done

[[ -d "$payload" ]] || { echo "error: no payload directory at $payload" >&2; exit 66; }
[[ -f "$payload/$PROGRAM" ]] || { echo "error: payload has no $PROGRAM" >&2; exit 66; }
[[ -f "$payload/$CODE_MODE_HOST_BIN" ]] || {
    echo "error: payload has no $CODE_MODE_HOST_BIN" >&2
    exit 66
}

[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
[[ "$install_prefix" =~ ^(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] || { echo "error: invalid install prefix" >&2; exit 64; }

case "$architecture:$install_prefix" in
iphoneos-arm64:/var/jb | iphoneos-arm64e:) ;;
*) echo "error: architecture and install prefix name different bootstrap layouts" >&2; exit 64 ;;
esac

for tool in ldid dpkg-deb xcrun vtool; do
    command -v "$tool" >/dev/null || { echo "error: $tool is not installed" >&2; exit 69; }
done

for binary in "$payload/$PROGRAM" "$payload/$CODE_MODE_HOST_BIN"; do
    vtool -show-build "$binary" 2>/dev/null | grep -qE '^ *platform (IOS|2)$' || {
        echo "error: $binary is not an iOS binary" >&2
        exit 65
    }
done

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd -- "$(dirname -- "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"

staging="$(mktemp -d "${TMPDIR:-/tmp}/${PROGRAM}-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/${PROGRAM}-entitlements.XXXXXX")"
trap 'rm -rf -- "$staging"; rm -f -- "$temporary_deb" "$signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_root="$staging$install_prefix"
installed_libexec="$installed_root/usr/libexec/$PROGRAM"
installed_launcher="$installed_root/usr/bin/$PROGRAM"
installed_system_config="$installed_root/etc/codex/config.toml"
mkdir -p "$debian" "$(dirname "$installed_libexec")" "$(dirname "$installed_launcher")" "$(dirname "$installed_system_config")"

/usr/bin/ditto "$payload" "$installed_libexec"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun clang -target "arm64-apple-ios$MIN_IOS" -isysroot "$sdk_path" -Os -fvisibility=hidden \
    "-DOG_PROGRAM=\"$PROGRAM\"" "-DOG_STATIC_PREFIX=\"$install_prefix\"" \
    "$launcher_source" -Wl,-dead_strip -o "$installed_launcher"
/usr/bin/ditto "$system_config" "$installed_system_config"
chmod 0644 "$installed_system_config"

chmod 0755 \
    "$installed_launcher" \
    "$installed_libexec/$PROGRAM" \
    "$installed_libexec/$CODE_MODE_HOST_BIN"
chmod -R a+rX "$installed_libexec"

vtool -show-build "$installed_launcher" 2>/dev/null | grep -qE '^ *platform (IOS|2)$' || {
    echo "error: launcher is not an iOS binary" >&2
    exit 65
}

for binary in \
    "$installed_launcher" \
    "$installed_libexec/$PROGRAM" \
    "$installed_libexec/$CODE_MODE_HOST_BIN"; do
    ldid -S"$entitlements" -Cadhoc "$binary"
done
shopt -s nullglob
for library in "$installed_libexec"/*.dylib; do
    ldid -S -Cadhoc "$library"
    chmod 0755 "$library"
done
shopt -u nullglob

require_true() {
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$signed_entitlements" 2>/dev/null || true)" == true ]] || {
        echo "error: signed binary is missing entitlement: $1" >&2
        exit 65
    }
}
for binary in \
    "$installed_launcher" \
    "$installed_libexec/$PROGRAM" \
    "$installed_libexec/$CODE_MODE_HOST_BIN"; do
    ldid -e "$binary" >"$signed_entitlements"
    require_true platform-application
    require_true com.apple.private.security.no-sandbox
    require_true com.apple.private.security.storage.AppBundles
    require_true com.apple.private.security.storage.AppDataContainers
    require_true com.apple.developer.kernel.extended-virtual-addressing
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.security.container-required' \
        "$signed_entitlements" 2>/dev/null || true)" == false ]] || {
        echo "error: $binary needs com.apple.private.security.container-required = false" >&2
        exit 65
    }
done

installed_size="$(du -sk "$installed_root" | awk '{print $1}')"
upstream_label="${UPSTREAM_REPO##*/}@${UPSTREAM_REF:0:12}"
sed \
    -e "s|@PACKAGE_ID@|$package_id|g" \
    -e "s|@VERSION@|$version|g" \
    -e "s|@ARCHITECTURE@|$architecture|g" \
    -e "s|@INSTALLED_SIZE@|$installed_size|g" \
    -e "s|@MIN_IOS@|$MIN_IOS|g" \
    -e "s|@UPSTREAM@|$upstream_label|g" \
    "$control_template" >"$debian/control"
chmod 0644 "$debian/control"
if grep -q '@[A-Z_]*@' "$debian/control"; then
    echo "error: control still holds unsubstituted placeholders:" >&2
    grep -n '@[A-Z_]*@' "$debian/control" | sed 's/^/       /' >&2
    exit 65
fi

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb" >/dev/null

[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
for path in \
    "$install_prefix/usr/bin/$PROGRAM" \
    "$install_prefix/usr/libexec/$PROGRAM/$PROGRAM" \
    "$install_prefix/usr/libexec/$PROGRAM/$CODE_MODE_HOST_BIN" \
    "$install_prefix/etc/codex/config.toml"; do
    grep -qF ".$path" <<<"$contents" || {
        echo "error: package is missing $path" >&2
        exit 65
    }
done
if grep -q 'SKILL.md' <<<"$contents"; then
    echo "error: package contains extra skill trees (SKILL.md)" >&2
    grep 'SKILL.md' <<<"$contents" | sed 's/^/       /' >&2
    exit 65
fi
"$skill_policy_check" --config "$installed_system_config" --tree "$installed_root" --payload "$payload"

mv -f "$temporary_deb" "$output_deb"
echo "packaged $package_id $version ($architecture, prefix '${install_prefix:-/}'): $output_deb"
shasum -a 256 "$output_deb"
