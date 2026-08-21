#!/usr/bin/env bash
#
# Install one .deb onto a jailbroken device over SSH and smoke-test it.
#
#   DEVICE_HOST  default 127.0.0.1
#   DEVICE_PORT  default 4422
#   DEVICE_USER  default mobile
#   DEVICE_SUDO_PASSWORD  only needed where sudo is not already passwordless

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <deb|package-directory>" >&2
    exit 64
fi

target="$1"
[[ -e "$target" ]] || { echo "error: no such package or directory: $target" >&2; exit 66; }

device_host="${DEVICE_HOST:-127.0.0.1}"
device_port="${DEVICE_PORT:-4422}"
device_user="${DEVICE_USER:-mobile}"
sudo_password="${DEVICE_SUDO_PASSWORD:-}"

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../Configuration/upstream.env
source "$repository_root/Configuration/upstream.env"
: "${PROGRAM:?}"
: "${CODE_MODE_HOST_BIN:?}"
package_id_expected="${PACKAGE_ID:-wiki.qaq.codex}"
package_version_expected="$(tr -d '[:space:]' <"$repository_root/Configuration/version.txt")"

ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -p "$device_port"
)
remote="$device_user@$device_host"

on_device() { ssh "${ssh_options[@]}" "$remote" "$@"; }

if ! on_device true 2>/dev/null; then
    echo "error: cannot reach $remote on port $device_port" >&2
    echo "hint: over USB, forward the device's sshd first:  iproxy $device_port:2222 &" >&2
    exit 69
fi

device_architecture="$(on_device 'dpkg --print-architecture')"

if [[ -d "$target" ]]; then
    deb="$target/${package_id_expected}_${package_version_expected}_${device_architecture}.deb"
    [[ -f "$deb" ]] || {
        echo "error: expected current package $deb" >&2
        exit 66
    }
else
    deb="$target"
fi

package_architecture="$(dpkg-deb -f "$deb" Architecture)"
if [[ "$package_architecture" != "$device_architecture" ]]; then
    echo "error: this device installs '$device_architecture' packages, not '$package_architecture'" >&2
    case "$device_architecture" in
    iphoneos-arm64) echo "hint: build the rootless package:  make deb-rootless" >&2 ;;
    iphoneos-arm64e) echo "hint: build the roothide package:  make deb-roothide" >&2 ;;
    esac
    exit 65
fi

package_id="$(dpkg-deb -f "$deb" Package)"
package_version="$(dpkg-deb -f "$deb" Version)"
echo "installing $package_id $package_version ($package_architecture) on $remote"

staged="/tmp/$(basename "$deb")"
scp -q -P "$device_port" -o BatchMode=yes "$deb" "$remote:$staged"
trap 'on_device "rm -f '"$staged"'" >/dev/null 2>&1 || true' EXIT

if on_device 'sudo -n true' 2>/dev/null; then
    run_privileged() { on_device "sudo -n $1"; }
elif [[ -n "$sudo_password" ]]; then
    run_privileged() {
        printf '%s\n' "$sudo_password" | ssh "${ssh_options[@]}" "$remote" "sudo -S -p '' $1"
    }
else
    echo "error: sudo on the device needs a password; set DEVICE_SUDO_PASSWORD" >&2
    exit 77
fi

run_privileged "dpkg -i $staged"

prefix=""
[[ "$package_architecture" == "iphoneos-arm64" ]] && prefix="/var/jb"
for path in \
    "$prefix/usr/bin/$PROGRAM" \
    "$prefix/usr/libexec/$PROGRAM/$PROGRAM" \
    "$prefix/usr/libexec/$PROGRAM/$CODE_MODE_HOST_BIN"; do
    on_device "test -e '$path'" || { echo "error: $path is missing after install" >&2; exit 65; }
done
for path in \
    "$prefix/usr/bin/$PROGRAM" \
    "$prefix/usr/libexec/$PROGRAM/$PROGRAM" \
    "$prefix/usr/libexec/$PROGRAM/$CODE_MODE_HOST_BIN"; do
    on_device "test -x '$path'" || {
        echo "error: $path is not executable" >&2
        exit 65
    }
done

echo "==> which $PROGRAM"
on_device "command -v $PROGRAM" || {
    echo "error: $PROGRAM is installed but not on PATH" >&2
    exit 65
}

echo "==> $PROGRAM --version"
on_device "$PROGRAM --version" || {
    echo "error: --version failed on device" >&2
    exit 65
}

echo "==> $CODE_MODE_HOST_BIN --help"
on_device "$prefix/usr/libexec/$PROGRAM/$CODE_MODE_HOST_BIN --help >/dev/null" || {
    echo "error: $CODE_MODE_HOST_BIN failed to start on device" >&2
    exit 65
}

echo "installed and smoke-tested $package_id $package_version on $remote"
