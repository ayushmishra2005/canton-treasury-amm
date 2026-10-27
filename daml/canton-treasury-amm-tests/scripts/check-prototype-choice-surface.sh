#!/usr/bin/env bash
# Change-control check for the prototype templates, not a security proof: it lists every choice
# (and, for the live-reserve model, every interface instance) the compiled prototypes expose and
# fails when that surface differs from the reviewed one. A difference means the new or changed
# entry needs a security review before its expected list below is updated. It cannot judge an
# edited body of an existing choice. Run after `dpm build --all`.
set -euo pipefail

cd "$(dirname "$0")/../.."

surface() {
  local dar=$1 module=$2
  dpm damlc inspect "$dar" \
    | sed -nE \
      -e "s/^ *(non-consuming|consuming) choice ([A-Za-z0-9_]+) \(self : ContractId ${module}:([A-Za-z0-9_]+)\).*/\3 \1 \2/p" \
      -e "s/^ *interface instance [0-9a-f]+:([A-Za-z0-9_.]+:[A-Za-z0-9_]+) for ${module}:([A-Za-z0-9_]+)$/\2 implements \1/p" \
    | LC_ALL=C sort -u
}

status=0
check() {
  local label=$1 dar=$2 module=$3 expected=$4 actual
  actual=$(surface "$dar" "$module")
  if [ "$actual" != "$expected" ]; then
    echo "$label choice surface changed; review before updating the expected list." >&2
    diff <(echo "$expected") <(echo "$actual") >&2 || true
    status=1
  else
    echo "$label choice surface matches the reviewed list."
  fi
}

check "Authenticated pool prototype" \
  canton-treasury-amm-tests/.daml/dist/canton-treasury-amm-tests-0.1.0.dar \
  'CantonTreasuryAmm\.Test\.ProtectedPoolPrototype' \
  'CounterfeitPool consuming Archive
CounterfeitPool consuming CounterfeitWithdraw
PoolCharter consuming Archive
PoolCharter consuming InitializePool
PoolPosition consuming Archive
ProtectedPool consuming AddLiquidity
ProtectedPool consuming Archive
ProtectedPool consuming RemoveLiquidity
ProtectedPool consuming SwapExactInput'

check "Live-reserve prototype" \
  canton-treasury-amm-live-reserve-prototype/.daml/dist/canton-treasury-amm-live-reserve-prototype-0.1.0.dar \
  'CantonTreasuryAmm\.LiveReservePrototype' \
  'LiveCharter consuming Archive
LiveCharter consuming InitializePool
LivePool consuming AddLiquidity
LivePool consuming Archive
LivePool consuming RemoveLiquidity
LivePool consuming SwapExactInput
LivePosition consuming Archive
ReserveHolding consuming AbsorbDeposit
ReserveHolding consuming Archive
ReserveHolding consuming Disburse
ReserveHolding implements Splice.Api.Token.HoldingV1:Holding'

exit $status
