#!/usr/bin/env bash
# Change-control check for the deployable and prototype packages, not a security proof: it
# lists every template each deployable DAR's main package defines, plus every choice and
# interface instance of the prototype and Secure V1 templates, and fails when either differs
# from the reviewed list. A difference means the new or changed entry needs a security review
# before its expected list below is updated. It cannot judge an edited body of an existing
# choice. Run after `dpm build --all`.
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

templates() {
  dpm damlc inspect "$1" \
    | awk '/^module [A-Za-z0-9_.]+ where$/ { module = $2 }
           /^template [A-Za-z0-9_]+ this where$/ { print module ":" $2 }' \
    | LC_ALL=C sort -u
}

status=0
compare() {
  local label=$1 expected=$2 actual=$3
  if [ "$actual" = "$expected" ]; then
    echo "$label matches the reviewed list."
  else
    echo "$label changed; review before updating the expected list." >&2
    diff <(echo "$expected") <(echo "$actual") >&2 || status=1
  fi
}

check() {
  compare "$1 choice surface" "$4" "$(surface "$2" "$3")"
}

inventory() {
  compare "$1 template inventory" "$3" "$(templates "$2")"
}

inventory "Legacy production package" \
  canton-treasury-amm/.daml/dist/canton-treasury-amm-0.1.0.dar \
  'CantonTreasuryAmm.LiquidityPosition:LiquidityPosition
CantonTreasuryAmm.Pool:Pool
CantonTreasuryAmm.Pool:PoolSetup
CantonTreasuryAmm.SwapIntent:SwapIntent
CantonTreasuryAmm.SwapIntent:SwapIntentFactory
CantonTreasuryAmm.Token:Holding
CantonTreasuryAmm.Token:TokenInstrument'

inventory "Secure V1 production package" \
  canton-treasury-amm-secure-v1/.daml/dist/canton-treasury-amm-secure-v1-0.1.0.dar \
  'CantonTreasuryAmm.SecureV1.Onboarding:SecurePoolProposal
CantonTreasuryAmm.SecureV1.Onboarding:SecureSwapIntentExecutionApproval
CantonTreasuryAmm.SecureV1.Onboarding:SecureSwapIntentFactoryProposal
CantonTreasuryAmm.SecureV1.Pool:SecureLiquidityPosition
CantonTreasuryAmm.SecureV1.Pool:SecurePool
CantonTreasuryAmm.SecureV1.Pool:SecurePoolCharter
CantonTreasuryAmm.SecureV1.Pool:SecureReserveHolding
CantonTreasuryAmm.SecureV1.SwapIntent:SecureSwapIntent
CantonTreasuryAmm.SecureV1.SwapIntent:SecureSwapIntentFactory'

inventory "Live-reserve prototype package" \
  canton-treasury-amm-live-reserve-prototype/.daml/dist/canton-treasury-amm-live-reserve-prototype-0.1.0.dar \
  'CantonTreasuryAmm.LiveReservePrototype:LiveCharter
CantonTreasuryAmm.LiveReservePrototype:LivePool
CantonTreasuryAmm.LiveReservePrototype:LivePosition
CantonTreasuryAmm.LiveReservePrototype:ReserveHolding'

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

check "Secure V1 production pool" \
  canton-treasury-amm-secure-v1/.daml/dist/canton-treasury-amm-secure-v1-0.1.0.dar \
  'CantonTreasuryAmm\.SecureV1\.Pool' \
  'SecureLiquidityPosition consuming Archive
SecurePool consuming AddLiquidity
SecurePool consuming Archive
SecurePool consuming RemoveLiquidity
SecurePool consuming SwapExactInput
SecurePoolCharter consuming Archive
SecurePoolCharter consuming InitializePool
SecureReserveHolding consuming Archive
SecureReserveHolding implements Splice.Api.Token.HoldingV1:Holding'

check "Secure V1 production swap intent" \
  canton-treasury-amm-secure-v1/.daml/dist/canton-treasury-amm-secure-v1-0.1.0.dar \
  'CantonTreasuryAmm\.SecureV1\.SwapIntent' \
  'SecureSwapIntent consuming Archive
SecureSwapIntent consuming Cancel
SecureSwapIntent consuming Execute
SecureSwapIntentFactory consuming Archive
SecureSwapIntentFactory non-consuming SubmitSwapIntent'

check "Secure V1 production onboarding" \
  canton-treasury-amm-secure-v1/.daml/dist/canton-treasury-amm-secure-v1-0.1.0.dar \
  'CantonTreasuryAmm\.SecureV1\.Onboarding' \
  'SecurePoolProposal consuming ApprovePoolProposal
SecurePoolProposal consuming Archive
SecurePoolProposal consuming CancelPoolProposal
SecurePoolProposal consuming FinalizePoolProposal
SecureSwapIntentExecutionApproval consuming Archive
SecureSwapIntentExecutionApproval consuming CancelExecutionApproval
SecureSwapIntentExecutionApproval consuming ExecuteApprovedIntent
SecureSwapIntentFactoryProposal consuming AcceptFactoryProposal
SecureSwapIntentFactoryProposal consuming Archive
SecureSwapIntentFactoryProposal consuming CancelFactoryProposal'

exit $status
