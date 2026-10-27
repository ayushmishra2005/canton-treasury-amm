# Legacy-to-Secure V1 migration design

This is a design for moving liquidity from legacy pools into Secure V1. It is not authorized and
must not be executed as written. It contains no live commands, archives no legacy position, moves
no legacy reserve and promises no in-place upgrade. Every step needs its own approval, its own
tooling review and a rehearsal on a non-production network.

**Default: parallel deployment.** The legacy package (`canton-treasury-amm` 0.1.0,
`d8cadd3c…`) stays deployed and unchanged. Secure V1 (`canton-treasury-amm-secure-v1` 0.1.0,
`e4546c3f…`) is vetted alongside it as a separate package; see
[`RELEASE_READINESS.md`](RELEASE_READINESS.md#packaging-and-coexistence). Liquidity moves only
through each LP's own legacy `RemoveLiquidity` and a fresh Secure V1 deposit. Legacy contracts
stay bound to the legacy package; nothing converts them.

## Why copying a legacy pool or position is insufficient

- **Different identity.** A legacy `PoolId` is the operator, governance, the two instruments and
  a setup reference. A Secure V1 pool is identified by its `SecureLineage`, which adds the
  custodian, together with its genesis, the contract ID of a consumed `SecurePoolCharter`. A
  genesis exists only once its charter has been consumed by `InitializePool`, and nothing
  derives one from a legacy pool. A copied `PoolId` authenticates nothing: every Secure V1
  choice rejects reserves and positions that are not of its own lineage and genesis.
- **Different signatories.** Legacy positions are signed by the operator and governance only.
  Secure V1 positions are signed by the provider and the four core signers. Smart Contract
  Upgrade applies only to a later version of the same package name and template, and it
  requires the upgraded template to compute the same signatories for existing contracts. The
  Secure V1 templates are different templates in a differently named package, so no upgrade
  path exists.
- **Copying is forgery.** Only the full core can create a `SecureLiquidityPosition` outside a
  deposit, and doing so is the unbacked-state power documented in
  [`SECURITY.md`](SECURITY.md#what-the-full-core-can-do). A copied position would carry no
  deposited reserves. It would also dilute every honest LP in the target pool.
- **Legacy claims are not self-authenticating.** The operator and governance could have created
  legacy positions with no deposit, and providers can burn positions outside `RemoveLiquidity`.
  Duplicate legacy pool states can also exist (all characterized in
  [`SECURITY.md`](SECURITY.md#legacy-amm)). A legacy position's share count is therefore not
  proof of a valid claim. Only redemption through the legacy pool, against its live reserves
  and recorded supply, turns it into assets.
- **Copying reserves bypasses LP accounting.** Legacy reserves are operator-owned `Holding`s.
  Moving them into Secure V1 would use the operator's unilateral `TransferExact`, which is the
  diversion that Secure V1 exists to prevent. It would also take value from LPs who have not
  redeemed.

## Runbook

1. **Identify legacy pools and outstanding positions.** Each legacy participant runs read-only
   active-contract queries for the legacy package's `Pool`, `PoolSetup`, `LiquidityPosition`
   and `SwapIntent` templates. The results are grouped by `PoolId`. A `PoolId` with more than one
   active `Pool` is a duplicate-state incident: stop and escalate. Output: a signed inventory
   with the ledger offset of the query.
2. **Snapshot pool state and reserve contract IDs.** For each pool, record the active `Pool`
   payload at that offset: reserve contract IDs and amounts, `totalShares`, `lockedShares`, both
   fee counters and `stateVersion`. Record each reserve `Holding` payload. Snapshots from the
   operator, governance and each issuer must agree.
3. **Confirm reserve activeness.** Both referenced reserves must be active, owned by the
   operator, of the pool's instruments, with amounts equal to the pool's recorded amounts. Any
   mismatch or inactive reserve is handled by step 8. Repeat this check immediately before and
   after every later step: an operator diversion appears as a reserve archived outside a `Pool`
   transaction.
4. **Identify LP owners and outstanding claims.** List every active `LiquidityPosition` per
   `PoolId`, with its provider, shares and auditors. Each provider confirms its position off-ledger.
   A position no provider recognizes, or one created in a transaction without a matching
   deposit, is flagged as possibly forged and not honored outside the legacy pool's own rules.
5. **Reconcile total shares.** Check that the sum of active positions plus `lockedShares`
   equals `totalShares`. A shortfall indicates unaccounted burns, whose value stays in the
   reserves for the remaining LPs. An excess indicates forgery or duplicate state. Record the
   discrepancy and resolve it with the affected LPs before any withdrawal window. The tooling
   must not correct it on-ledger.
6. **Handle legacy operator-controlled reserves.** Do not move, merge, split or archive them.
   They leave the pool only through LP redemptions. The locked share and rounding dust remain
   after the last withdrawal. What happens to them is a separate, LP-communicated decision,
   which this design does not authorize. Throughout the window, monitor the reserves under
   step 3.
7. **Coordinate withdrawals by legitimate LPs.** Each LP submits its own legacy `RemoveLiquidity`
   from its own participant. The operator supplies fresh disclosures of the pool and reserves.
   LPs set their own minimum outputs. Each withdrawal consumes the pool state, so withdrawals
   are serialized and each one needs the current `stateVersion`.

   Legacy has no pause. If the operator stops issuing fresh disclosures and stops executing
   intents, new swaps are discouraged, because a stale disclosure stops working once the state
   changes. That is a coordination measure only, not a security control. Withdrawal is never
   performed on an LP's behalf.
8. **Handle a pool already frozen by a consumed reserve.** If a referenced reserve is inactive
   (operator diversion, issuer archival or a duplicate-state settlement), every legacy pool
   choice fails and LPs cannot redeem. Treat this as an incident. Record the snapshot and the
   transaction that consumed the reserve. Do not create a replacement `Pool`: the operator and
   governance can, but that is the forgery power. Any restoration needs the issuers and every
   affected LP to agree, an independently reconciled amount, and a separately reviewed
   procedure. Migration of that pool stops until then.
9. **Reinitialize an independently authorized Secure V1 pool.** The four core signers create a
   new `SecurePoolCharter` with a fresh `charterReference`, the pool auditors and an initial
   provider, through the proposal and approval workflow in [`ONBOARDING.md`](ONBOARDING.md),
   which no custodian or issuer has yet reviewed (see
   [`RELEASE_READINESS.md`](RELEASE_READINESS.md#remaining-blockers)). The initial provider
   deposits redeemed assets through `InitializePool`. The initial ratio sets the starting price.
   It should match the legacy pool's last price, so that the first trades do not hand an
   arbitrage to the market at LPs' expense. Further LPs join through `AddLiquidity` with their
   own maxima and minimum shares. Fee counters start at zero.
10. **Confirm the new reserve holdings.** Query `SecureReserveHolding` from every core and
    auditor participant. Exactly two reserves of the new lineage and genesis must exist, with
    amounts equal to the pool's recorded amounts. Instrument totals (ordinary holdings plus
    Secure V1 reserves plus any remaining legacy reserves) must be unchanged by the migration
    transactions.
11. **Establish custodian and issuer approvals.** This happens before step 9:
    - the custodian is onboarded as an independent organization;
    - each issuer formally agrees to co-sign and confirm every pool transaction;
    - each core, governance, auditor, trader and provider participant uploads and vets the Secure
      V1 package;
    - hosting of every core party on its own participant is verified from the participants
      themselves, as `MultiParticipant:mpVerifyHosting` does;
    - signer separation and key custody are reviewed (see [`SECURITY.md`](SECURITY.md#signer-separation)).
12. **Validate the initial Secure V1 accounting.** For the new state, check the following:
    - `totalShares = floor(sqrt(treasuryAtoms · stableAtoms))`, with one locked share and a
      provider position of `totalShares − 1`;
    - version 0 and both fee counters at 0;
    - reserves equal to the deposits;
    - change returned to the provider;
    - the charter archived.

    Repeat the check from every core participant and the auditor.
13. **Communicate the cutover boundary.** The Secure V1 pool is a new pool, not a continuation:
    - LPs receive new shares at the new pool's ratio;
    - legacy fee history does not carry over;
    - legacy intents and factories do not apply, so traders use a new `SecureSwapIntentFactory`;
    - the legacy pool keeps its legacy trust model for as long as it holds liquidity.

    Publish the ledger offsets of the last legacy withdrawal window and of the Secure V1
    initialization. State that Secure V1 is a trusted-custody design whose core can halt the
    pool.
14. **Handle unsuccessful or partial migration attempts.** Each redemption, initialization and
    deposit is atomic, so a failure leaves the previous state intact:
    - Re-check steps 3 and 5 before retrying, and never retry by copying state.
    - A partial migration is a valid end state. Both pools run in parallel, and LPs who have not
      redeemed keep their legacy positions.
    - If the new Secure V1 pool is found to be wrong after initialization, LPs exit through its
      `RemoveLiquidity`. The locked share and dust remain, and there is no on-ledger path back
      to legacy positions.
    - If a legacy pool freezes mid-migration, apply step 8.
    - Keep every snapshot and reconciliation as evidence.

## Implementation gaps

The following are not implemented:
- inventory, snapshot and reconciliation tooling;
- an onboarding procedure agreed with the custodian and issuers (the workflow itself is in
  [`ONBOARDING.md`](ONBOARDING.md));
- a legacy withdrawal-window procedure;
- a Secure V1 pause (see [`SECURITY.md`](SECURITY.md#emergency-stop-and-recovery-design));
- a decision on legacy dust;
- a rehearsal on a non-production network.
