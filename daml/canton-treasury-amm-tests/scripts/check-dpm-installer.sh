#!/usr/bin/env bash
# Negative tests for install-dpm-verified.sh: every case must fail before anything is extracted
# or run. With an ARCHIVE argument (the real tarball for this platform) it also checks that the
# archive verifies and that one flipped byte in a copy of it does not.
#
# Usage: check-dpm-installer.sh [ARCHIVE]
set -euo pipefail

installer="$(cd "$(dirname "$0")" && pwd)/install-dpm-verified.sh"
real_archive=${1:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# expect_refusal NAME MESSAGE COMMAND...: COMMAND must exit non-zero, print MESSAGE, and leave
# no marker from the fake bin/dpm.
expect_refusal() {
  local name=$1 message=$2
  shift 2
  rm -f "$work/ran"
  local code=0
  "$@" > "$work/out.log" 2>&1 || code=$?
  if [ "$code" -eq 0 ]; then
    echo "FAIL $name: the installer exited 0"; failures=$((failures + 1))
  elif ! grep -qF -- "$message" "$work/out.log"; then
    echo "FAIL $name: refused for another reason:"; cat "$work/out.log"; failures=$((failures + 1))
  elif [ -e "$work/ran" ]; then
    echo "FAIL $name: archive content ran"; failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) os=unknown ;; esac
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) arch=unknown ;; esac
platform=$os-$arch
size=$(sed -n "s/^  $platform) size=\([0-9]*\) .*/\1/p" "$installer")
[ -n "$size" ] || { echo "No pinned archive for this host ($platform)"; exit 1; }

# A tarball whose bin/dpm leaves a marker when run, padded with zeros to the pinned size of this
# platform's archive, so only the SHA-256 check stands between it and execution.
mkdir -p "$work/fake/dpm/bin" "$work/control"
printf '#!/bin/sh\ntouch "%s/ran"\n' "$work" > "$work/fake/dpm/bin/dpm"
chmod +x "$work/fake/dpm/bin/dpm"
tar czf "$work/fake.tar.gz" -C "$work/fake" dpm
python3 -c 'import os, sys; os.truncate(sys.argv[1], int(sys.argv[2]))' "$work/fake.tar.gz" "$size"
tar xzf "$work/fake.tar.gz" -C "$work/control" --strip-components 1 2> /dev/null
"$work/control/bin/dpm"
[ -e "$work/ran" ] || { echo "Control failed: the padded fake archive does not run when extracted"; exit 1; }
echo "ok   control: the padded fake archive extracts and runs when nothing verifies it"

# A uname that reports an architecture with no pinned archive.
mkdir -p "$work/uname-bin"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = -m ] && { echo riscv64; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$work/uname-bin/uname"
chmod +x "$work/uname-bin/uname"

expect_refusal "wrong version" "is not the pinned 3.5.5" bash "$installer" 3.5.4 "$work/fake.tar.gz"
expect_refusal "latest version" "is not the pinned 3.5.5" bash "$installer" latest "$work/fake.tar.gz"
expect_refusal "empty version" "is not the pinned 3.5.5" bash "$installer" "" "$work/fake.tar.gz"
expect_refusal "no version" "usage:" bash "$installer"
expect_refusal "unsupported architecture" "unsupported architecture riscv64" \
  env PATH="$work/uname-bin:$PATH" bash "$installer" 3.5.5 "$work/fake.tar.gz"
expect_refusal "unpinned platform" "no pinned digest for platform linux-riscv64" \
  env AMM_DPM_VERIFY_ONLY=1 AMM_DPM_PLATFORM=linux-riscv64 bash "$installer" 3.5.5 "$work/fake.tar.gz"
expect_refusal "platform override outside verification" "only accepted with AMM_DPM_VERIFY_ONLY=1" \
  env AMM_DPM_PLATFORM="$platform" bash "$installer" 3.5.5 "$work/fake.tar.gz"
expect_refusal "missing archive" "does not exist" bash "$installer" 3.5.5 "$work/absent.tar.gz"
head -c 1000 "$work/fake.tar.gz" > "$work/short.tar.gz"
expect_refusal "truncated archive" "expected $size" bash "$installer" 3.5.5 "$work/short.tar.gz"
expect_refusal "modified archive installs nothing" "expected" bash "$installer" 3.5.5 "$work/fake.tar.gz"

if [ -n "$real_archive" ]; then
  if AMM_DPM_VERIFY_ONLY=1 bash "$installer" 3.5.5 "$real_archive" > "$work/out.log" 2>&1; then
    echo "ok   real archive verifies"
  else
    echo "FAIL real archive did not verify:"; cat "$work/out.log"; failures=$((failures + 1))
  fi
  other=linux-arm64
  [ "$platform" != linux-arm64 ] || other=linux-amd64
  expect_refusal "another platform's digest" "expected" \
    env AMM_DPM_VERIFY_ONLY=1 AMM_DPM_PLATFORM="$other" bash "$installer" 3.5.5 "$real_archive"
  cp "$real_archive" "$work/flipped.tar.gz"
  python3 - "$work/flipped.tar.gz" << 'EOF'
import sys
with open(sys.argv[1], "r+b") as archive:
    archive.seek(1 << 20)
    byte = archive.read(1)
    archive.seek(1 << 20)
    archive.write(bytes([byte[0] ^ 1]))
EOF
  expect_refusal "real archive with one flipped byte" "expected" \
    env AMM_DPM_VERIFY_ONLY=1 bash "$installer" 3.5.5 "$work/flipped.tar.gz"
fi

[ "$failures" -eq 0 ] || { echo "$failures installer check(s) failed"; exit 1; }
echo "All installer checks passed."
