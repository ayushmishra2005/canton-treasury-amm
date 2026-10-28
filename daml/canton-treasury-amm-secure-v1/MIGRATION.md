# Legacy-to-Secure V1 migration design

This is a design for moving liquidity from legacy pools into Secure V1. It is not authorized and
must not be executed against real assets. It contains no live commands, archives no legacy
position, moves no legacy reserve and promises no in-place upgrade. It has been rehearsed with
synthetic assets only (see [Rehearsal](#rehearsal)). A real migration still needs its own
approval for every step, reviewed tooling, and the approvals listed in
[`RELEASE_READINESS.md`](RELEASE_READINESS.md#remaining-blockers).

**Default: parallel deployment.** The legacy package (`canton-treasury-amm` 0.1.0,
`d8cadd3c…`) stays deployed and unchanged. Secure V1 (`canton-treasury-amm-secure-v1` 0.2.0,
`4abe2905…`) is vetted alongside it as a separate package; see
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
   with the ledger offset of the query. Each pool then goes through
   [Lineage verification](#lineage-verification) against its independently recorded anchor, and
   only a VERIFIED pool continues. Active contracts alone cannot show that a state is genuine.
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
   transaction that consumed the reserve (the verifier's `RESERVE_DIVERTED` reason names the
   reserve and the choice that consumed it). Do not create a replacement `Pool`: the operator and
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

## Atomicity and coordination

No transaction spans the migration. Each of the following is atomic on its own, so a failure
leaves the state before it:

| Step | Atomic unit | Who submits |
| --- | --- | --- |
| Legacy exit (step 7) | One `RemoveLiquidity`: the position burns, both payouts go to the provider, the pool state moves by exactly the payout | The provider |
| Charter onboarding (step 9) | Each proposal, approval and finalization separately; finalization creates the charter only with all four approvals before expiry | The operator, then each core signer, then the operator |
| Secure V1 initialization (step 9) | One `InitializePool`: both deposits, both reserves, the pool, the provider's position and the change | The initial provider |
| Each later deposit, swap or withdrawal | One Secure V1 choice | The LP or trader |

Everything between these steps is off-ledger coordination:
- the inventory, snapshots and reconciliation (steps 1–5, 10 and 12);
- the order in which LPs exit, since each exit consumes the legacy pool state;
- the time an LP holds its legacy proceeds before depositing them, during which they are
  ordinary holdings in its own name;
- the initial provider's choice of ratio, and when the charter is initialized;
- the decision that the migration of a pool is complete.

Between a provider's legacy exit and its Secure V1 deposit, no one else can move its proceeds.
Between initialization and a later LP's deposit, swaps can move the Secure V1 price, and that
LP sets its own maxima and minimum shares.

## Stop conditions

Stop the migration of a pool, record the evidence, and leave the decision to the people
named:

| Condition | Detected by | Who decides |
| --- | --- | --- |
| No active legacy `Pool` for the `PoolId`, or more than one | `LegacyPoolMissing`, `LegacyPoolDuplicated` | Operator, governance, both issuers |
| A referenced legacy reserve is inactive (step 8) | `LegacyReserveInactive` | Both issuers and every affected LP |
| A referenced reserve has another instrument, owner or amount than the pool records | `LegacyReserveMismatch` | Both issuers and every affected LP |
| Positions plus the locked share differ from `totalShares` (step 5) | `LegacySupplyMismatch` | Every affected LP |
| A provider does not recognize its position, or a position no provider claims | Step 4 | That provider and governance |
| An exit pays anything other than the computed claim, or another LP's claim falls | `checkLegacyExit` | Every affected LP |
| A Secure V1 approval or finalization fails for any reason other than an honest retry | Onboarding errors | The four core signers |
| The Secure V1 pool, its reserves, its positions or the instrument totals differ from the expectation | `secureMismatches` | The four core signers, both issuers |
| A core participant is unreachable for longer than an agreed window | Timed-out submissions | The four core signers; see [Pause and signer loss](#pause-and-signer-loss) |

In none of these cases does anyone create, archive, move or re-issue a contract to make the
numbers agree. A state that reconciles is not thereby genuine: a legacy pool archived and
re-created unchanged by the operator and governance passes every check of the procedure, and
only the ledger history shows it (scenario C of the rehearsal). Steps 1 and 8 therefore require
the transaction history of each pool state, not just the active contracts. That history check is
[Lineage verification](#lineage-verification); a pool that does not verify does not migrate.

## Lineage verification

`daml/canton-treasury-amm-tests/scripts/verify-legacy-lineage.py` checks one legacy pool's
history against a trusted starting point before its migration. It is read-only and needs only
the Python 3 standard library. It submits nothing and creates, archives or moves no contract.
It reads only through the documented JSON Ledger API v2 endpoints of Canton 3.5.12:
- `GET /v2/parties/{party}`, to check that the reader's party is hosted there (`isLocal`);
- `GET /v2/state/ledger-end`, which pins the offset the whole read refers to;
- `GET /v2/state/latest-pruned-offsets`;
- `POST /v2/updates/get-updates-page`, for every transaction from the pruning boundary to that
  offset, in the ledger-effects shape;
- `POST /v2/state/active-contracts`, at that offset.

Every read is scoped to the reader's own party. This is not an audit and does not replace one.
It is one piece of evidence that a human reviews before deciding anything.

**Outcomes.** The verifier gives exactly one of three outcomes. Its exit codes are 0, 2 and 3,
and 1 means unusable input.
- **VERIFIED:** the evidence that was read agrees with the anchor. The report lists what is
  still trusted.
- **BLOCKED:** the evidence contradicts the anchor or the legacy rules. That pool's migration
  stops.
- **INCOMPLETE EVIDENCE:** the evidence was not enough to decide. That pool's migration stops
  until the gap is closed.

BLOCKED outranks INCOMPLETE EVIDENCE, and INCOMPLETE EVIDENCE outranks VERIFIED. Every reason
carries a code and the contract or update it concerns. Both a JSON report and a human-readable
summary are written.

### The trusted anchor

The verifier authenticates nothing on its own. Ledger history shows how the current state
descends from an earlier one; it cannot show that the earlier one was the right pool. That
starting point, the *anchor*, must come from outside the ledger tooling. The manifest holds it:

| Field | Content |
| --- | --- |
| `legacyPackageId` | The reviewed legacy package (`d8cadd3c…`), from the release record, not from the ledger |
| `pool` | The `PoolId` and the pool auditors |
| `authorizedParties` | The operator and governance, exactly |
| `reserveInstruments` | The two instruments, which must equal those in the `PoolId` |
| `anchor` | `genesisCid`, the version-0 `Pool` created by `Initialize`, and `attestedBy`, the parties that recorded it |
| `provenance` | `recordedBy` (one of the attestors), and how and when it was recorded |
| `snapshot` | The `Pool` contract ID at the agreed snapshot boundary |
| `knownActiveStateCid` | The state the inventory presents as current |
| `positions` | Each provider's own confirmation of its shares, in atoms |
| `requireComplete` | Whether outstanding legacy positions block the verdict (a completion check) |

**How an auditor establishes the anchor.** When the pool is opened, the pool auditor's own
participant receives the `Initialize` transaction, because the auditor is an observer of the
`Pool` it creates. The auditor records the created `Pool` contract ID, the update ID and the
`PoolId` at that time, in its own records, outside the operator's control. That record is the
anchor. The verifier then re-checks the anchor against the auditor's participant:
- the anchor must be a `Pool` of the expected package, at version 0 with no fees;
- its signatories must be exactly the operator and governance;
- its `PoolId` and auditors must match the manifest;
- it must have been created inside a consuming `Initialize` of a legacy `PoolSetup`;
- no other `Initialize` may have created a pool with the same `PoolId`.

The anchor's status is reported as one of four values:
- **independently verified:** an attestor other than the operator and governance is a pool
  stakeholder whose own participant confirms the anchor, and that attestor recorded it;
- **claimed but unverified:** the anchor is attested only by the operator or governance, was
  recorded by someone else, or no independent stakeholder can see it. The result is INCOMPLETE
  EVIDENCE. An anchor supplied by the operator is never accepted, however well the balances
  reconcile;
- **conflicting:** the history contradicts the anchor, giving BLOCKED. Examples are a state not
  created by `Initialize`, a second genesis, or different fields;
- **missing:** there is no anchor or no attestor, giving INCOMPLETE EVIDENCE.

An issuer cannot anchor a pool on its own. Issuers are not `Pool` stakeholders, so they never
see pool states. They do see every move of their reserve holdings, and they confirm the reserves.

### What the history can and cannot show

From the anchor, the verifier follows each pool state to its successor in the auditor's
history. Each consuming exercise must be `SwapExactInput`, `AddLiquidity` or `RemoveLiquidity`
of the expected package. It must create exactly one successor with the same `PoolId` at the
next version, and the choice's result must name that successor. The verifier then requires all
of the following:
- the last state is the only active state;
- every other state with this `PoolId` is reported;
- the inventory's state and the snapshot are in the lineage. A snapshot earlier than the current
  state is accepted, and the legitimate transitions since it are listed;
- every `LiquidityPosition` of the pool was created inside the genesis `Initialize`, an
  `AddLiquidity` or a `RemoveLiquidity` of the lineage, and was consumed only inside a lineage
  `RemoveLiquidity`;
- the active positions plus the locked share equal `totalShares`;
- the active positions equal the providers' confirmations, also as read from each provider's own
  participant where a reader is given;
- in each issuer's history, every reserve of every lineage state was created in a lineage update
  and consumed only in the update that consumed the state holding it. Issuers' participants see
  the reserve moves but not the pool exercise around them, so the two views are matched by update
  ID, which is the same on every participant;
- the current reserves are active, of the pool's instruments, owned by the operator, and hold the
  recorded amounts.

This shows that the current state descends, through the legacy package's own pool choices, from
the anchored genesis. It also shows that no position or reserve of the pool was created or
consumed outside those choices, as far as the readers can see.

It cannot show:
- that the anchor was the right pool to begin with;
- that the readers' participants report their history honestly;
- that the legacy package does what its review says;
- what happened before the oldest unpruned offset;
- what happens after the read.

A reconciled balance is not evidence of a lineage: a faithful re-creation and a forged position
with a matching supply both pass the [snapshot procedure](#rehearsal) and are BLOCKED here.

### Required visibility

- **The pool auditor**, or another independent pool stakeholder, read on the participant that
  hosts it. Without one the result is `NO_INDEPENDENT_VIEW`. A pool with no auditors cannot be
  verified by anyone other than its operator and governance.
- **Both issuers**, each read on its own participant. Without one the result is
  `RESERVE_EVIDENCE_MISSING`.
- **Each confirming provider**, optionally, on its own participant.

A reader whose party is not hosted on the given participant is not used (`READER_NOT_HOSTED`).
An administrator's or another participant's view does not substitute for the party's own.

In production, each reader needs a JSON API access token scoped to `readAs` its own party, and
each party gathers its own evidence. The local test network has no JSON API authentication, and
the test checks query each party only on its own participant. That reflects the test setup, not
an auditor capability.

### Missing history and conflicting state

Missing evidence is reported as INCOMPLETE EVIDENCE, never as success:
- `HISTORY_PRUNED`: a reader's participant has pruned past the genesis;
- `ANCHOR_NOT_VISIBLE`: the anchor is not in the reader's history;
- `READER_UNAVAILABLE`: an endpoint failed, or the update stream stopped before the pinned
  offset;
- `RESERVE_ORIGIN_UNKNOWN` on a pruned issuer participant;
- `STATE_CHANGED`: the inventory is older than the current state, so it must be re-taken.

Conflicting state is BLOCKED, with codes such as `LINEAGE_BROKEN`, `UNACCOUNTED_STATE`,
`DUPLICATE_ACTIVE_STATE`, `POSITION_OUTSIDE_LINEAGE`, `SUPPLY_MISMATCH`, `POSITION_MISMATCH`,
`RESERVE_DIVERTED`, `RESERVE_INACTIVE`, `RESERVE_MISMATCH`, `UNEXPECTED_PACKAGE`,
`ANCHOR_CONFLICT`, `ANCHOR_NOT_GENESIS` and `CONFLICTING_GENESIS`.

A duplicate is reported only among the states the readers can see. The verifier does not claim
that no other copy exists.

**Retention.** Pruning ends the ability to verify. Every participant that is read must keep its
history from the genesis until the migration is decided. That is the auditor's, and for
reserves each issuer's, and it includes any automatic pruning schedule. If retention cannot be
guaranteed, the anchor record should include each reader's own record of the lineage as it
happens. This design does not provide that record.

### Legacy reserve diversion

Legacy reserves are operator-owned holdings, and the operator can move them at any time with
`TransferExact`. The verifier detects a diversion that has already happened: the reserve is
consumed outside a pool transition, and the pool is frozen (`RESERVE_DIVERTED`,
`RESERVE_INACTIVE`). It can prevent neither a diversion nor its recurrence, and it cannot return
the value. A diversion after the read is covered by step 3's repeated checks, and not by this
verdict. See step 8 for a pool that is already frozen.

### Evidence and approval

For each pool, keep the following:
- the manifest, the anchor record and its provenance;
- the readers file, without tokens;
- the JSON report;
- the ledger end and pruning offset of each reader.

The report's offsets bound what it covers.

VERIFIED is not an approval. Cutover of a pool needs a human decision, recorded with the
report, by the parties listed under [Stop conditions](#stop-conditions). Every remaining trusted
assumption in the report must be accepted explicitly.

The readers' participants must be re-read immediately before each legacy exit, because the
verdict says nothing about later transactions. Multi-LP exits are not atomic (see
[Atomicity and coordination](#atomicity-and-coordination)), so each exit is a new
time-of-check/time-of-use window.

### Limitations

The verifier does not remove any of these threats; it only reports what it can see:
- a full core, or the operator and governance together, can still do everything listed in
  [`SECURITY.md`](SECURITY.md#legacy-amm), for example archive, re-create or forge state;
- issuers can still archive or mint their instruments;
- participants that serve false or partial history, or a synchronizer that sequences a different
  history, defeat it;
- off-ledger coordination is outside it;
- it reads JSON API list endpoints. An active contract set larger than the participant's
  `http-list-max-elements-limit` fails the read and gives INCOMPLETE EVIDENCE, not a partial
  answer.

It recognizes pool-like contracts by a `poolId` field equal to the manifest's; a copy that
renames the field is not recognized as pool-like.

It authorizes no live migration. It has run only against synthetic pools on a local network (see
[Rehearsal](#rehearsal)).

## Pause and signer loss

The Secure V1 pause ([`PAUSE.md`](PAUSE.md)) stops trading and deposits in the new pool while
LPs exit. It needs all four core signers, and so do paused exits: an offline core participant
blocks both. Pausing is therefore an option during migration only while every core signer is
available. It is not a remedy for an unavailable or compromised signer.

There is no recovery from permanent loss of a core signer. Every pool that signer signs, paused
or not, can no longer move, and the rest of the core cannot release its reserves. The decisions
this needs are listed in [`PAUSE.md`](PAUSE.md#permanent-signer-loss) and are unmade. Archiving
a pool state or reserve with all signatories destroys its record of value; it is not recovery.
Legacy pools have no pause.

## Rehearsal

The runbook was rehearsed with synthetic assets, on the production templates of both packages,
and with no live participant. Two harnesses use the same reconciliation procedure
(`CantonTreasuryAmm.Test.MigrationRehearsal`). It reads every state as the pool auditor and the
issuers see it, never as the operator reports it, and finds the legacy pool by its `PoolId`.

**Setup shortcuts.** Both harnesses issue the synthetic balances and create the legacy
`PoolSetup` directly. Legacy has no onboarding workflow. On the IDE ledger, the operator and
governance create it in one submission. On Canton, the operator proposes it through the test-only
`LegacyPoolSetupProposal` and governance accepts it on its own participant. Everything after the
setup uses production choices only.

**Sequence (scenario A).**
1. The legacy pool starts at 5,000,000 / 10,000,000, so the initial provider holds 7,071,066
   shares.
2. A second LP adds 500,000 / 1,000,000 for 707,106 shares.
3. A trader swaps 10,000 Treasury for 19,903 (fee 30) and 5,000 stablecoin for 2,500 (fee 15).
4. The snapshot reconciles 5,507,500 / 10,985,097 and a supply of 7,778,173. The first LP's
   claim is 5,006,817 / 9,986,451 and the second's 500,681 / 998,644.
5. Each LP exits from its own submission and receives exactly its claim. The second claim rises
   to 500,682 / 998,644 after the first exit, and the legacy pool keeps 1 / 2 atoms of dust
   backing the locked share.
6. The Secure V1 charter is proposed, approved by both issuers and the custodian, and finalized.
7. The first LP initializes it from its proceeds (supply 7,071,091). The second deposits its
   proceeds for 707,108 shares, with 1 Treasury atom returned as change.
8. A swap of 1,000 pays 1,988, and the second LP withdraws 353,554 shares for 250,385 / 499,231.
9. The completion check finds no blocker. The pool holds 5,258,113 / 10,483,876 with a supply
   of 7,424,645, and the instrument totals equal the synthetic issuance throughout.

**Failure scenarios** (`Test/Migration.daml`, IDE ledger):

| Scenario | Test | Outcome |
| --- | --- | --- |
| A, success | `migrationMovesBothProvidersIntoSecureV1` | As above |
| B, partial | `partialMigrationKeepsTheRemainingLegacyClaim` | After one exit, completion reports `LegacyPositionsOutstanding`. The remaining LP's claim is intact and later settles. Legacy and Secure V1 positions are rejected by the other pool (`WronglyTypedContract`) |
| C, diversion | `divertedLegacyReserveBlocksMigration` | An operator `TransferExact` of a reserve yields `LegacyReserveInactive`. Every exit then fails (`ContractNotFound`), and the diverted value sits with the recipient. No recovery is attempted |
| C, tampered state | `tamperedLegacyStateBlocksMigration` | A duplicate pool state, a forged position, an overstated reserve, a reserve that is another party's holding, and a direct position burn are each reported. A faithful re-creation is not |
| D, missing approval | `missingCoreApprovalCreatesNoCharter` | Without any one core approval, finalization fails `amm/onboarding-incomplete`, a direct create fails authorization, and no charter exists |
| E, interrupted onboarding | `interruptedOnboardingIsRetriedWithFreshApprovals` | A replayed approval fails, an expired proposal can be neither approved (`amm/deadline`) nor finalized, and it is cancelled. A fresh proposal succeeds |
| F, failed initialization | `failedSecureInitializationLosesNothing` | Another LP's proceeds fail (`ContractNotFound` unless disclosed, then `amm/owner-mismatch`), as do a deposit above the holding (`amm/insufficient-balance`) and swapped instruments (`amm/instrument-mismatch`). An LP that is not the charter's provider cannot reach it. Nothing moves; the retry succeeds |
| G, duplicate submission | `duplicatedMigrationStepsSettleOnce` | A resubmitted legacy exit (with the old disclosures, or against the new state), finalization, initialization or deposit fails on consumed contracts. Each step settles once |
| H, reconciliation mismatch | `reconciliationMismatchBlocksCompletion` | Wrong expected reserves, supply, positions or totals are each reported. A paused pool is reported as not active; after resume the check passes |

**Local multi-participant Canton.** `scripts/run-multi-participant.sh` runs scenario A end to
end as `mpMigrationAllocate` and `mpMigrationRehearsal`, after the earlier phases. The second LP
is allocated on a ninth participant, `second_provider`, and each role submits from its own
participant. The phases also check that a replayed legacy exit fails on the consumed state, and
that a wrong completion expectation is reported. This is a local, in-memory network, not
evidence about a production topology.

**Lineage verification on Canton.** `run-multi-participant.sh` then runs
`LegacyLineage:mpLineageScenarios`, which creates one legacy pool per scenario with synthetic
`LUST` / `LUSD` instruments, each role submitting from its own participant. The pools are:
- genuine;
- recreated: a faithful re-creation after a swap;
- diverted: an operator `TransferExact` of a reserve;
- forged: a 1,000-share position, with a re-created state whose supply includes it;
- duplicated: a second identical active state;
- burned: a provider's standalone partial `BurnPosition`;
- fullyBurned: a second LP's standalone burn of its whole position;
- regenesis: the genesis archived and re-created at version 0;
- unobserved: a pool with no auditors;
- legitimate: snapshot taken, then a swap, a partial exit and a deposit;
- partial: one of two LPs has exited;
- complete: the only LP has exited.

The operator's and governance's joint actions go through the test-only `LegacyStateRewrite`,
which governance applies on its own participant. It stands for any code those two could vet and
use together. The phase asserts that the [snapshot procedure](#rehearsal) reconciles both the
faithful re-creation and the forgery.

`scripts/check-legacy-lineage.py` builds a manifest for each check from what the independent
parties observed. It runs the verifier with each party read on its own participant's JSON API
and requires the exact verdict and exit code, the listed reason codes, and no reason at all for
VERIFIED. The auditor's participant is then pruned for real, past the genuine pool's genesis,
and that pool is checked again.

| Check | Verdict | Reasons |
| --- | --- | --- |
| Genuine | VERIFIED | Anchor independently verified |
| Genuine, wrong expected package ID | BLOCKED | `UNEXPECTED_PACKAGE`, `ANCHOR_CONFLICT`, `ANCHOR_NOT_GENESIS` |
| Genuine, anchor attested only by the operator | INCOMPLETE EVIDENCE | `ANCHOR_UNVERIFIED`, `ANCHOR_PROVENANCE` |
| Genuine, no anchor | INCOMPLETE EVIDENCE | `ANCHOR_MISSING` |
| Genuine, auditor read through the trader's participant | INCOMPLETE EVIDENCE | `READER_NOT_HOSTED`, `NO_INDEPENDENT_VIEW` |
| Genuine, without the issuers' views | INCOMPLETE EVIDENCE | `RESERVE_EVIDENCE_MISSING` |
| Genuine, one LP's position left out of the confirmations | BLOCKED | `POSITION_MISMATCH` |
| Faithful re-creation | BLOCKED | `LINEAGE_BROKEN` (consumed by `Archive`), `UNACCOUNTED_STATE` |
| Re-created state as the anchor, attested by the operator | BLOCKED | `ANCHOR_NOT_GENESIS`, `ANCHOR_CONFLICT`, `ANCHOR_UNVERIFIED`, `ANCHOR_PROVENANCE` |
| Re-created state as the anchor, attested by the auditor | BLOCKED | `ANCHOR_NOT_GENESIS`, `ANCHOR_CONFLICT` |
| Reserve diversion | BLOCKED | `RESERVE_DIVERTED`, `RESERVE_INACTIVE` |
| Forged position with a matching supply | BLOCKED | `LINEAGE_BROKEN`, `UNACCOUNTED_STATE`, `POSITION_OUTSIDE_LINEAGE` |
| Duplicate active state | BLOCKED | `DUPLICATE_ACTIVE_STATE` |
| Standalone partial burn | BLOCKED | `POSITION_OUTSIDE_LINEAGE`, `SUPPLY_MISMATCH` |
| Standalone burn of a whole position | BLOCKED | `POSITION_OUTSIDE_LINEAGE`, `SUPPLY_MISMATCH` |
| Version-0 re-creation of the genesis as the anchor, attested by the auditor | BLOCKED | `ANCHOR_NOT_GENESIS` only |
| The same pool with the true anchor | BLOCKED | `LINEAGE_BROKEN`, `UNACCOUNTED_STATE` |
| No auditors, attested by the Treasury issuer | INCOMPLETE EVIDENCE | `NO_INDEPENDENT_VIEW` |
| Legitimate changes after the snapshot | VERIFIED | 3 post-snapshot transitions listed |
| Inventory older than the current state | INCOMPLETE EVIDENCE | `STATE_CHANGED` |
| Snapshot from another pool's history | BLOCKED | `SNAPSHOT_NOT_IN_LINEAGE` |
| Partial migration, completion required | BLOCKED | `MIGRATION_INCOMPLETE` |
| Partial migration, inventory only | VERIFIED | |
| Complete migration, completion required | VERIFIED | |
| Genuine, after the auditor's participant was pruned past the genesis | INCOMPLETE EVIDENCE | `HISTORY_PRUNED` |

**Visibility as observed.** The auditor's participant receives the following:
- every `Initialize`, swap, deposit and withdrawal, with its node range;
- the bare `Pool` `Archive` and the root-level `Pool` creates of a rewrite. It does not receive
  the rewrite's own exercise, because the auditor is not its stakeholder;
- the out-of-pool `TransferExact` and `BurnPosition`.

The issuers receive each reserve move but not the pool exercise around it. The pool auditors in
these scenarios also observe the holdings, but the verifier uses the issuers' views for
reserves, because holding auditors are not guaranteed.

**Pruning on the local network.** Canton offers a safe pruning offset only up to the
participant's maximum deduplication duration back, and only once ACS commitments have been
exchanged. The test topology sets `init.ledger-api.max-deduplication-duration = 10s` on the
auditor participant only, and `prune-auditor.canton` pings the other participants until an
offset is offered. Both are administrator actions on the test network. They are not a capability
of the auditor's party.

**Not rehearsed.**
- A real inventory across participants with ledger offsets and signed snapshots.
- An anchor recorded at the time of a real pool's opening.
- Authenticated JSON API access.
- Communication with real LPs and issuers.
- A decision on legacy dust.
- An LP withdrawal window under load.
- Any non-local network.

The custodian and issuers have not agreed an onboarding or pause procedure.
