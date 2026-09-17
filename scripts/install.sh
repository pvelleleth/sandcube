#!/bin/sh
# Release publishing replaces the three @...@ values. No unverified fallback.
set -eu
repository='@REPOSITORY@'
version='@VERSION@'
public_key='@PUBLIC_KEY_BASE64@'
systemd=false
deps=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --systemd) systemd=true ;;
    --no-deps) deps=false ;;
    --help) echo 'Usage: install.sh [--systemd] [--no-deps]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$public_key" in @*) echo 'Use the install.sh attached to a signed Sandcube release.' >&2; exit 1 ;; esac
[ "$(uname -s)" = Linux ] || { echo 'Sandcube requires Linux' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'Supported architectures: x86_64 and aarch64' >&2; exit 1 ;;
esac
. /etc/os-release
case "$ID" in
  ubuntu|debian|fedora|rhel|rocky|almalinux|centos) ;;
  *) if "$deps"; then echo "Unsupported distribution: $ID; use --no-deps and install prerequisites manually" >&2; exit 1; fi ;;
esac
as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}
# Bootstrap only the tools required to verify a release.
if ! command -v openssl >/dev/null || ! command -v curl >/dev/null; then
  case "$ID" in
    ubuntu|debian) as_root apt-get update; as_root apt-get install -y ca-certificates curl openssl ;;
    fedora|rhel|rocky|almalinux|centos) as_root dnf install -y ca-certificates curl openssl ;;
    *) echo 'Install curl and openssl first' >&2; exit 1 ;;
  esac
fi
work=$(mktemp -d /tmp/sandcube-install.XXXXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
printf '%s' "$public_key" | openssl base64 -d -A > "$work/release.pem"
base="https://github.com/$repository/releases/download/v$version"
download() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$base/$1" -o "$work/$1"; }
download SHA256SUMS
download SHA256SUMS.sig
openssl dgst -sha256 -verify "$work/release.pem" -signature "$work/SHA256SUMS.sig" "$work/SHA256SUMS" >/dev/null
verified_download() {
  name=$1
  expected=$(awk -v name="$name" '$2 == name { print $1 }' "$work/SHA256SUMS")
  [ "${#expected}" = 64 ] || { echo "Missing or duplicate checksum: $name" >&2; exit 1; }
  download "$name"
  actual=$(sha256sum "$work/$name" | cut -d ' ' -f 1)
  [ "$actual" = "$expected" ] || { echo "Checksum mismatch: $name" >&2; exit 1; }
}
binary="sandcube-linux-$arch"
verified_download "$binary"
if "$systemd"; then verified_download sandcube.service; fi
if "$deps"; then
  verified_download install-deps.sh
  as_root sh "$work/install-deps.sh"
fi
as_root install -d -m 0755 /usr/local/bin
staged_binary="/usr/local/bin/.$(basename "$work")"
as_root install -m 0755 "$work/$binary" "$staged_binary"
as_root mv -f "$staged_binary" /usr/local/bin/sandcube
if "$systemd"; then
  as_root install -m 0644 "$work/sandcube.service" /etc/systemd/system/sandcube.service
  as_root systemctl daemon-reload
  as_root systemctl enable sandcube.service
fi
echo "Installed sandcube $version. Next: sudo sandcube init, then sudo sandcube serve"
