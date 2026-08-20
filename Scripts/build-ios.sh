#!/usr/bin/env bash
#
# Cross-compile the Cargo product for iOS out of a prepared source tree, verify
# the result is really an iOS binary, and assemble a payload directory.
#
# Prints the payload directory on stdout (the last line). Its contents are
# exactly what lands in <prefix>/usr/libexec/<program>.

set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <src-dir> <scratch-dir>" >&2
    exit 64
fi

src_dir="$1"
scratch_dir="$2"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../Configuration/upstream.env
source "$repository_root/Configuration/upstream.env"

: "${CARGO_DIR:?}"
: "${CARGO_PACKAGE:?}"
: "${CARGO_BIN:?}"
: "${PROGRAM:?}"
: "${MIN_IOS:?}"
: "${ARCH:?}"
: "${RUST_TOOLCHAIN:?}"

cargo_root="$src_dir/$CARGO_DIR"
[[ -f "$cargo_root/Cargo.toml" ]] || {
    echo "error: $cargo_root is not a prepared Cargo tree (run Scripts/prepare-source.sh)" >&2
    exit 66
}

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
[[ -d "$sdk_path" ]] || { echo "error: no iPhoneOS SDK; install Xcode" >&2; exit 69; }

# rustc's apple-ios target is aarch64-apple-ios, not arm64-apple-ios.
case "$ARCH" in
arm64) rust_target="aarch64-apple-ios" ;;
*)     rust_target="$ARCH-apple-ios" ;;
esac

echo "building $CARGO_PACKAGE ($CARGO_BIN) for $rust_target (iOS $MIN_IOS)" >&2
echo "  SDK:       $sdk_path" >&2
echo "  toolchain: $RUST_TOOLCHAIN" >&2

command -v rustup >/dev/null || { echo "error: rustup is not installed" >&2; exit 69; }
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal >&2
rustup target add "$rust_target" --toolchain "$RUST_TOOLCHAIN" >&2

export SDKROOT="$sdk_path"
export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS"
export MACOSX_DEPLOYMENT_TARGET=""
# Stop pkg-config from feeding macOS .pc files into an iOS link.
export PKG_CONFIG_ALLOW_CROSS=1
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR || true

mkdir -p "$scratch_dir"
cargo_home="$scratch_dir/cargo-home"
mkdir -p "$cargo_home"
export CARGO_HOME="$cargo_home"
export CARGO_TARGET_DIR="$scratch_dir/target"

# Host rustc would happily emit a darwin Mach-O if the target flag is dropped.
# The vtool check below is the backstop; this is the front.
(
    cd "$cargo_root"
    cargo +"$RUST_TOOLCHAIN" build \
        --release \
        --target "$rust_target" \
        --package "$CARGO_PACKAGE" \
        --bin "$CARGO_BIN"
) >&2

executable="$CARGO_TARGET_DIR/$rust_target/release/$CARGO_BIN"
[[ -f "$executable" ]] || { echo "error: build produced no $executable" >&2; exit 65; }

build_version="$(vtool -show-build "$executable" 2>/dev/null)"
grep -qE '^ *platform (IOS|2)$' <<<"$build_version" || {
    echo "error: $executable is not an iOS binary:" >&2
    sed 's/^/       /' <<<"$build_version" >&2
    exit 65
}

architectures="$(lipo -archs "$executable")"
[[ "$architectures" == "$ARCH" ]] || {
    echo "error: expected a $ARCH binary, got '$architectures'" >&2
    exit 65
}

while read -r dependency; do
    case "$dependency" in
    @*) ;;
    /usr/lib/* | /System/Library/Frameworks/*) ;;
    *)
        echo "error: $executable depends on a path iOS does not provide: $dependency" >&2
        exit 65
        ;;
    esac
done < <(otool -L "$executable" | tail -n +2 | awk '{print $1}')

payload="$scratch_dir/payload"
rm -rf -- "$payload"
mkdir -p "$payload"
/usr/bin/ditto "$executable" "$payload/$PROGRAM"

{
    echo "built $PROGRAM: $architectures, iOS $MIN_IOS minimum, $(
        du -h "$payload/$PROGRAM" | cut -f1 | tr -d ' '
    )"
    echo "payload ($(du -sh "$payload" | cut -f1 | tr -d ' ') total):"
    (cd "$payload" && find . -maxdepth 1 -mindepth 1 | sed 's|^\./|  |')
    echo "system dependencies:"
    otool -L "$payload/$PROGRAM" | tail -n +2 | awk '{print "  " $1}'
} >&2

printf '%s\n' "$payload"
