#!/bin/sh
# Run after both architecture binaries have been built into dist/.
set -eu
: "${RELEASE_VERSION:?Set RELEASE_VERSION (without v)}"
: "${RELEASE_REPOSITORY:?Set RELEASE_REPOSITORY (owner/repo)}"
: "${RELEASE_SIGNING_KEY:?Set RELEASE_SIGNING_KEY to an RSA private PEM file}"
case "$RELEASE_VERSION" in ''|*[!0-9A-Za-z._-]*) echo 'Invalid version' >&2; exit 1 ;; esac
case "$RELEASE_REPOSITORY" in ''|*[!0-9A-Za-z_./-]*) echo 'Invalid repository' >&2; exit 1 ;; esac
test -f dist/sandcube-linux-amd64
test -f dist/sandcube-linux-arm64
cp scripts/install-deps.sh dist/install-deps.sh
cp infra/systemd/sandcube.service dist/sandcube.service
openssl pkey -in "$RELEASE_SIGNING_KEY" -pubout -out dist/release.pem
public_key=$(openssl base64 -A -in dist/release.pem)
sed -e "s|@REPOSITORY@|$RELEASE_REPOSITORY|g" -e "s|@VERSION@|$RELEASE_VERSION|g" -e "s|@PUBLIC_KEY_BASE64@|$public_key|g" scripts/install.sh > dist/install.sh
cd dist
sha256sum sandcube-linux-amd64 sandcube-linux-arm64 install-deps.sh sandcube.service install.sh > SHA256SUMS
openssl dgst -sha256 -sign "$RELEASE_SIGNING_KEY" -out SHA256SUMS.sig SHA256SUMS
openssl dgst -sha256 -verify release.pem -signature SHA256SUMS.sig SHA256SUMS
