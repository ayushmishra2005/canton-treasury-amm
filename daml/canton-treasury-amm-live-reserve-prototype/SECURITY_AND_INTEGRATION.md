# Live-reserve prototype: security model and integration assessment

PROTOTYPE ONLY. `CantonTreasuryAmm.LiveReservePrototype` is an isolated package. It does not
modify, replace or deploy the production AMM in `daml/canton-treasury-amm`. This model is not
trustless and not noncustodial: it relies on an independent custodian and on the joint
signatures of the parties listed below.

## Asset models

| Model | Status | Evidence |
| --- | --- | --- |
| A. Existing ordinary `Holding` as a reserve | NOT FEASIBLE without changing `Token.daml` | `ordinaryHoldingCannotServeAsProtectedReserve` |
| B. Protected custom live holding (`ReserveHolding`) | PROTOTYPED | the `LiveReservePrototypeTests` module |
| C. Arbitrary Token Standard holding | UNSUPPORTED | not attempted; see below |

A. A production `Holding` is signed by its issuer alone. Its owner alone controls `TransferExact`
and `Merge`. Its issuer alone can archive it, so a reserve held as a `Holding` is exposed to
unilateral issuer archival. A custodian-owned `Holding` can be moved by the custodian alone. No
wrapper can remove either power without changing the `Holding` template itself.

B. `ReserveHolding` is a separate template that the instrument issuers must adopt and co-sign.
Deposits are conversions. The depositor's own `TransferExact` moves the deposited `Holding` to
the custodian; the issuer's authority then archives it, and a reserve successor grows by exactly
that amount. Payouts are the reverse conversion: a new ordinary `Holding`, and a reserve
successor smaller by exactly that amount. This is on-ledger unit conservation that the issuers
authorize. Nothing on the ledger evidences off-ledger backing of either kind of holding.

C. `Splice.Api.Token.HoldingV1` declares a view and no choices. Moving a third-party holding
requires that registry's transfer or allocation APIs, which are separate packages and are not
introduced here. Newer Token Standard DARs and CIP-112 are not used.

## Trust model

The core signers are the custodian, the operator, the Treasury issuer and the stablecoin issuer,
and they must be distinct. Every `LiveCharter`, `LivePool` and `ReserveHolding` is signed by all
four. A `LivePosition` is also signed by its provider. Governance is a distinct observer.

The custodian is assumed independent and trusted. An independent custodian does not remove the
need for trust; it adds a required co-signer.

PROTECTED (tested on the IDE ledger; S1, S3 and S7 also on a Canton sandbox):
- Operator alone, issuer alone, operator plus governance, and all 29 non-empty subsets of
  {custodian, operator, governance, treasury issuer, stable issuer} lacking a core signer cannot:
  move, archive or create a reserve; create a pool state or position; or draw from or retire a
  reserve through a mandate they grant (S1, S2, S3, S10).
- Forged LP shares: Phase 0 `LiquidityPosition`s are the wrong template for redemption, and no
  coalition short of the full core can create a `LivePosition` (S4).
- Counterfeit pools that reference genuine reserve contract IDs cannot pay out (S5).
- Holdings owned by someone else cannot be deposited (S6). The owner check is layered: with it
  removed, the owner-controlled `TransferExact` still fails with an authorization error.
- Stale state: wrong versions, consumed pools, reserves and positions, stale explicit disclosures,
  and replays are all rejected without a state change (S7).
- Stage 1.1 custody mandates, release requests, joint releases and coalition sweeps cannot act
  on a `ReserveHolding` (`WronglyTypedContract`). Generic mandates granted by any party set short
  of the four core signers cannot draw from or retire reserves (S8).
- A failure late in a transaction rolls the whole transaction back (S9).
- A pool accepts only reserves of its own genesis and redeems only positions of its own genesis.

NOT PROTECTED (the full core coalition is a trust boundary; see `fullCoreCoalitionRemainsTrusted`):
- The four core signers together can create unbacked reserves, positions and pool states, and so
  inflate on-ledger units.
- They can drain a genuine reserve through any contract they all sign. This includes a mandate
  granted by three of them to the fourth.
- They can archive a pool. A pool whose reserve was drained this way freezes, because it
  references a consumed reserve.
- They can create a second charter with an identical lineage. That creates a second, separately
  bound pool, not a merge with the first.
- Any one core signer can halt the pool by refusing to confirm (liveness, below).
- Off-ledger backing, custody and redemption are not modelled.

Choice bodies run with the authority of the full core. For example, `AbsorbDeposit` carries
issuer authority that could archive any holding of that instrument. Safety therefore depends on
the reviewed choice bodies, not on authorization alone. The bodies archive only the holding the
depositor itself moved to the custodian.

## Choice-surface control

`scripts/check-prototype-choice-surface.sh` in the tests package compares the compiled choice
and interface-instance list against a reviewed list:

- `LiveCharter`: `Archive`, `InitializePool`.
- `LivePool`: `AddLiquidity`, `Archive`, `RemoveLiquidity`, `SwapExactInput`.
- `LivePosition`: `Archive`.
- `ReserveHolding`: `AbsorbDeposit`, `Archive`, `Disburse`, plus its `HoldingV1` instance.

Adding `AdminWithdraw`, `UnrestrictedTransfer`, `IndependentBurn`, `EmergencySweep` or
`UnboundedRelease` (consuming or nonconsuming) fails the check. The check detects any change to
the surface, not unsafe semantics: a harmful edit inside an existing choice body passes it.
A reviewer other than the author of the change must approve every update to the expected list
and every change to a choice body. Contracts that the full core signs are outside this control.

## Token Standard V1 view

Each `ReserveHolding` implements `Splice.Api.Token.HoldingV1.Holding`:

- `owner`: the custodian.
- `instrumentId`: the issuer and symbol.
- `amount`: the exact reserve amount.
- `lock`: holders are the four core signers, with no expiry and context "AMM pool reserve; moves
  only through pool settlement". It is not `None`, because the reserve cannot be moved by its
  reported owner alone.
- `meta`: the charter reference.

The view is visible only to stakeholders (the four core signers and governance). Traders,
providers and auditors do not see reserves unless they are disclosed. Interface totals reconcile
with template totals. The view grants no transfer capability.

## Package separation

- This package depends only on `daml-prim`, `daml-stdlib`, the two vendored splice API DARs and
  the production AMM DAR. It has no `daml-script` dependency and builds without warnings.
- The tests package depends on it as a data-dependency. `multi-package.yaml` orders it as
  production, then this package, then tests.
- The tests package still emits `template-interface-depends-on-daml-script`, because it defines
  test-only templates (Stage 1.x prototypes and `LiveReserveAdversary`). The warning is not
  suppressed.

## Liveness and disclosure

- Every swap and every liquidity change creates contracts that all four core signers sign, so
  participants hosting the custodian, the operator and both issuers must confirm it. A slow,
  offline or censoring core signer halts the pool.
- A trader or provider needs the current pool and both current reserves by explicit disclosure,
  delivered off-ledger by a stakeholder. Withholding disclosure denies access.
- On Canton 3.5.12 (SDK 3.5.5), stale-state attempts were rejected either at submission
  (`CONTRACT_NOT_FOUND`) or at confirmation (`LOCAL_VERDICT_INACTIVE_CONTRACTS`). The IDE ledger
  reports `ContractNotFound`. Only a single-participant sandbox was tested.

## Integration impact on the production AMM

For each production operation: the current code path, the proposed path, and the gaps. Common
to every operation:
- Signatories change from operator and governance to the four core signers, plus the provider
  for positions.
- Schemas change from `PoolId` to a lineage with a genesis ID; reserves move from `Holding` to
  `ReserveHolding` contract IDs.
- Disclosure: users need the pool and both reserves, instead of only the pool.
- Migration: existing pools cannot be converted in place. Their reserves are ordinary
  operator-owned `Holding`s, so migration requires a full-core-signed cutover, LP-by-LP
  redemption, or re-initialization. No migration is prototyped.
- Residual trust: the full core coalition (see above).

1. `PoolSetup.Initialize` (`Pool.daml`): the provider transfers to the operator, then a `Pool` and
   a `LiquidityPosition` are created. Proposed: `LiveCharter.InitializePool` retires the
   deposits into two `ReserveHolding`s bound to the charter. The setup contract needs the core
   signatures. Tests to adapt: `Pool`, `Bounds`, `Authorization`.
2. `Pool.SwapExactInput`: production transfers the input to the operator, merges it, and
   transfers the output from the reserve. Proposed: `AbsorbDeposit` on the input reserve and
   `Disburse` on the output reserve. Fee reporting (`treasuryFeeAmount`, `stableFeeAmount`) and
   auditors are not prototyped and must be carried over. Tests to adapt: `Swap`, `Bounds`,
   `Authorization`.
3. `SwapIntent.Execute`: operator and governance call `SwapExactInput`. This is unchanged in
   shape, but the factory and intent need to reach the four core signers and the trader. Under
   the proposed model, governance has no authority over reserves. Not prototyped. Tests to
   adapt: `SwapIntent`.
4. `Pool.AddLiquidity`: as for swaps, with two absorbs. Tests to adapt: `Liquidity`.
5. `Pool.RemoveLiquidity`: as for swaps, with two disbursements. A payout never empties a
   reserve; the locked share and the payout rule keep at least one atom in each. Tests to adapt:
   `Liquidity`.
6. `Holding.TransferExact`: unchanged for ordinary holdings. No reserve path exists, which is by
   design. Tests to adapt: `Token`.
7. `Holding.Merge`: unchanged for ordinary holdings. Reserves grow by successor creation instead.
   Tests to adapt: `Token`.
8. `LiquidityPosition.BurnPosition`: the provider-controlled burn would be replaced by
   `RemoveLiquidity`. `LivePosition` has no provider-only burn, because its signatories include
   the core. A provider cannot discard shares on their own. Tests to adapt: `Liquidity`,
   `Authorization`.
9. `Archive` (implicit): it needs all signatories on every prototype template. No strict subset
   of them can archive a pool, reserve or position. Tests to adapt: `Authorization`.

Verdicts for Stage 2.2:
- A: NO-GO, unless `Token.daml` changes.
- B: CONDITIONAL GO, only for issuers that adopt and co-sign `ReserveHolding`, with a
  migration plan, fee reporting, `SwapIntent` adaptation, and a multi-participant liveness
  evaluation.
- C: UNSUPPORTED.
