#!/bin/sh
# Embedded in the signed release. Dependencies are pinned by version AND digest.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$#" -eq 0 ] || { echo 'Usage: install-deps.sh' >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo 'Dependency installation requires root' >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo 'Linux is required' >&2; exit 1; }
case "$(uname -m)" in
  x86_64)
    arch=amd64; gvarch=x86_64
    containerd_sum=ca26ef5138f17b847bbeeec36d4bf5e002b54d25858197a870c125d57f44d32f
    gvisor_sum=81416511897ab8abd4e723d66823c5b0461a2ee3311cfa70d152404ef9b860cf
    buildkit_sum=b6242896d343100808dcbe37565caf381e0a444a6a83d7255926bb1519248ead
    cni_sum=1a28a0506bfe5bcdc981caf1a49eeab7e72da8321f1119b7be85f22621013098 ;;
  aarch64|arm64)
    arch=arm64; gvarch=aarch64
    containerd_sum=2942d72435b18610f7b69c1ddb74f99cef5c549425ff80d3e74f04e5e80db6a4
    gvisor_sum=2b162adb35860f598ab2f89b9d752bff2c7ee6175c05d9cc532174a336cfb38c
    buildkit_sum=e5acfb5929f967fde3b925ddb39f79fd481a0e96774c641fab3a0e83950d7bfa
    cni_sum=119fcb508d1ac2149e49a550752f9cd64d023a1d70e189b59c476e4d2bf7c497 ;;
  *) echo 'Supported architectures: x86_64 and aarch64' >&2; exit 1 ;;
esac
. /etc/os-release
case "$ID" in
  ubuntu|debian)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl tar bzip2 iproute2 nftables conntrack procps util-linux xfsprogs kmod
    DEBIAN_FRONTEND=noninteractive apt-get install -y runc iptables ;;
  fedora|rhel|rocky|almalinux|centos)
    dnf install -y ca-certificates curl openssl tar bzip2 iproute nftables conntrack-tools procps-ng util-linux xfsprogs kmod
    dnf install -y runc iptables ;;
  *) echo "Unsupported distribution: $ID; install prerequisites manually (see sandcube doctor)" >&2; exit 1 ;;
esac

work=$(mktemp -d /tmp/sandcube-deps.XXXXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
download() {
  url=$1; expected=$2; destination=$3
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$url" -o "$destination"
  actual=$(sha256sum "$destination" | cut -d ' ' -f 1)
  [ "$actual" = "$expected" ] || { echo "Dependency checksum mismatch: $url" >&2; exit 1; }
}
# Private dependency prefix avoids replacing a host's Docker/containerd binaries.
prefix=/usr/local/lib/sandcube/deps
install -d -m 0755 "$prefix/bin"
download "https://github.com/containerd/containerd/releases/download/v2.2.3/containerd-2.2.3-linux-$arch.tar.gz" "$containerd_sum" "$work/containerd.tar.gz"
tar -xzf "$work/containerd.tar.gz" -C "$prefix" --no-same-owner
download "https://github.com/google/gvisor/releases/download/release-20260907.0/gvisor-$gvarch.tar.bz2" "$gvisor_sum" "$work/gvisor.tar.bz2"
tar -xjf "$work/gvisor.tar.bz2" -C "$prefix/bin" --no-same-owner

download "https://github.com/moby/buildkit/releases/download/v0.33.0/buildkit-v0.33.0.linux-$arch.tar.gz" "$buildkit_sum" "$work/buildkit.tar.gz"
tar -xzf "$work/buildkit.tar.gz" -C "$prefix" --no-same-owner
download "https://github.com/containernetworking/plugins/releases/download/v1.7.1/cni-plugins-linux-$arch-v1.7.1.tgz" "$cni_sum" "$work/cni.tgz"
install -d -m 0755 /opt/cni/bin
tar -xzf "$work/cni.tgz" -C /opt/cni/bin --no-same-owner
install -d -m 0700 /var/lib/sandcube /run/sandcube
install -d -m 0755 /etc/sysctl.d /etc/modules-load.d
printf '%s\n' 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-sandcube.conf
printf '%s\n' overlay > /etc/modules-load.d/sandcube.conf
modprobe overlay
sysctl -p /etc/sysctl.d/90-sandcube.conf
echo 'Dependencies installed. Run sandcube init, then sandcube serve.'
