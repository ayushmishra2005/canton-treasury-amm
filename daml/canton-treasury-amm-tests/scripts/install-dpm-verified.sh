#!/usr/bin/env bash
# Installs dpm with SDK 3.5.5 the way https://get.digitalasset.com/install/install.sh does
# (download dpm-VERSION-OS-ARCH.tar.gz from Digital Asset's Artifact Registry, extract it, run
# `dpm bootstrap`), but refuses to extract or run anything until the archive matches the size
# and SHA-256 pinned below. Fails closed: any other version, any unlisted platform, a missing or
# altered archive, or a missing checksum tool stops the install.
#
# Usage: install-dpm-verified.sh VERSION [ARCHIVE]
#   VERSION  must be the pinned SDK version.
#   ARCHIVE  a local copy of the tarball to verify and install instead of downloading it.
# AMM_DPM_VERIFY_ONLY=1 stops after verification; only then may AMM_DPM_PLATFORM name another
# platform's pinned digest to verify against.
#
# The digests are the SHA256 values Artifact Registry records for these files
# (projects/da-images/locations/europe/repositories/public-generic, package dpm-sdk, version
# 3.5.5, created 2026-08-12). They come from the publisher's registry, the same origin as the
# download, not from an independent signature.
set -euo pipefail

readonly pinned_version=3.5.5

fail() {
  echo "install-dpm-verified: $*" >&2
  exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail "usage: install-dpm-verified.sh VERSION [ARCHIVE]"
version=$1
archive=${2:-}
[ "$version" = "$pinned_version" ] || fail "SDK version '$version' is not the pinned $pinned_version"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) fail "unsupported operating system $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac
platform=$os-$arch
if [ -n "${AMM_DPM_PLATFORM:-}" ]; then
  [ "${AMM_DPM_VERIFY_ONLY:-0}" = 1 ] || fail "AMM_DPM_PLATFORM is only accepted with AMM_DPM_VERIFY_ONLY=1"
  platform=$AMM_DPM_PLATFORM
fi

case "$platform" in
  linux-amd64) size=1139346243 sha256=556e4e7ea446bcd1cf6278bb57a438492fecdef7f4748041f78ed77fc176d334 ;;
  linux-arm64) size=1157429957 sha256=b5d5df875269190d0a3a78f2e2dd9d749011eed9c960a5ad60e2fa4c0b38ea57 ;;
  darwin-amd64) size=1122889303 sha256=491c4f9b00871ad386da4515ddcbe76bfb38290e49120f11be2a4fbcd0ebb308 ;;
  darwin-arm64) size=1122192153 sha256=4b17c36088e4330ff28db325b4a037ba0b5cd387fa39c86022cf5a9acd082f60 ;;
  *) fail "no pinned digest for platform $platform" ;;
esac

if command -v sha256sum > /dev/null; then
  sha256_of() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum > /dev/null; then
  sha256_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  fail "no sha256sum or shasum to verify the archive with"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tarball="dpm-$version-$platform.tar.gz"
if [ -z "$archive" ]; then
  archive="$work/$tarball"
  url="https://artifactregistry.googleapis.com/download/v1/projects/da-images/locations/europe/repositories/public-generic/files/dpm-sdk:$version:$tarball:download?alt=media"
  echo "Downloading $url"
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$archive" || fail "download of $tarball failed"
fi
[ -f "$archive" ] || fail "archive $archive does not exist"

actual_size=$(wc -c < "$archive" | tr -d ' ')
[ "$actual_size" = "$size" ] || fail "$archive is $actual_size bytes, expected $size for $tarball"
actual_sha256=$(sha256_of "$archive")
[ "$actual_sha256" = "$sha256" ] || fail "$archive has SHA-256 $actual_sha256, expected $sha256 for $tarball"
echo "Verified $tarball: $size bytes, SHA-256 $sha256"

if [ "${AMM_DPM_VERIFY_ONLY:-0}" = 1 ]; then
  exit 0
fi

mkdir "$work/extracted"
tar xzf "$archive" -C "$work/extracted" --strip-components 1
[ -x "$work/extracted/bin/dpm" ] || fail "verified archive has no bin/dpm"
"$work/extracted/bin/dpm" bootstrap "$work/extracted"
echo "Installed dpm with SDK $version from the verified archive"
