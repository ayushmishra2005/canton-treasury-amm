#!/usr/bin/env bash
# Change-control check for the authenticated pool prototype, not a security proof: it lists
# every choice the compiled prototype templates expose and fails when that surface differs from
# the reviewed one in PROTOTYPE_SECURITY.md. A difference means the new or changed choice needs
# a security review before the expected list below is updated. Run after `dpm build --all`.
set -euo pipefail

cd "$(dirname "$0")/.."
dar=.daml/dist/canton-treasury-amm-tests-0.1.0.dar
module='CantonTreasuryAmm\.Test\.ProtectedPoolPrototype'

expected='CounterfeitPool consuming Archive
CounterfeitPool consuming CounterfeitWithdraw
PoolCharter consuming Archive
PoolCharter consuming InitializePool
PoolPosition consuming Archive
ProtectedPool consuming AddLiquidity
ProtectedPool consuming Archive
ProtectedPool consuming RemoveLiquidity
ProtectedPool consuming SwapExactInput'

actual=$(dpm damlc inspect "$dar" \
  | sed -nE "s/^ *(non-consuming|consuming) choice ([A-Za-z0-9_]+) \(self : ContractId ${module}:([A-Za-z0-9_]+)\).*/\3 \1 \2/p" \
  | LC_ALL=C sort -u)

if [ "$actual" != "$expected" ]; then
  echo "Prototype choice surface changed; review before updating the expected list." >&2
  diff <(echo "$expected") <(echo "$actual") >&2 || true
  exit 1
fi
echo "Prototype choice surface matches the reviewed list."
