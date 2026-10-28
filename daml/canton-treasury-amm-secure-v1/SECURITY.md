# Security model: legacy AMM and Secure V1

This document records the verified security behavior of the legacy AMM and of Secure V1. It
also covers the residual trust and emergency operations, and Token Standard compatibility. Each
claim names the test that demonstrates it. Nothing here is a guarantee beyond those tests and
the review described in [Source review](#source-review).

Secure V1 is a trusted-custody design. It is not trustless or fully noncustodial. It has not
been audited, and it is not ready for deployment. See [Deployment readiness](#deployment-readiness).

## Trust boundaries and residual risk (summary)

Each boundary names what the ledger enforces and what is still trusted. The sections below
hold the evidence.

- **Participant hosting.** Enforced: a participant can submit only for parties it hosts, and
  every pool transaction needs a confirmation from each core party's participant. Trusted: that
  the custodian, the operator, both issuers and governance really are separate organizations
  with separate participants and keys. The ledger only checks that the party IDs differ
  ([Signer separation](#signer-separation)).
- **Core signers and everyone else.** Enforced: charters, pool states and reserves carry all
  four core signatures, and no coalition missing a core signer can create, move or archive them
  (all 29 such subsets of the core plus governance are tested, see
  [Secure V1](#secure-v1)). Trusted: the full core coalition, which can
  forge, drain, freeze or destroy a pool ([What the full core can do](#what-the-full-core-can-do)).
- **Pool and reserves.** Enforced: reserves have no choices and change only inside pool choices
  that check lineage, genesis, instrument and the recorded amounts. Trusted: that the reviewed
  choice bodies are correct. The CI change-control checks are not a semantic proof
  ([Source review](#source-review)).
- **Traders and LPs.** Enforced: a deposit moves only through the depositor's own
  `TransferExact`, payouts go only to the controlling trader or provider, and a position cannot
  be archived without its provider. Trusted: intent executors choose which eligible holding to
  spend and when to execute ([Secure SwapIntent scope](#secure-swapintent-scope)).
- **Governance and auditors.** Enforced: neither holds reserve authority. Governance only
  co-controls the intent factory and intent executions; auditors only observe.
- **Issuers and ordinary holdings.** Unchanged from the legacy token model: each issuer alone
  can archive any ordinary `Holding` of its instrument, including payouts once they leave the
  pool ([Destroyable assets](#destroyable-assets-and-archivable-contracts)).
- **Legacy and Secure V1.** Enforced: a legacy diversion cannot reach Secure V1 reserves.
  Trusted: legacy pools keep operator custody and operator-with-governance forgery until they
  are drained ([Legacy AMM](#legacy-amm)).
- **Migration evidence.** The lineage verifier is read-only and only reports. Trusted: the
  independently recorded anchor, honest history from the readers' participants, and retention
  back to the genesis. VERIFIED is not an approval
  ([`MIGRATION.md`](MIGRATION.md#lineage-verification)).
- **Canton infrastructure.** Out of scope: synchronizer and participant operators, key
  management and networking. Tested only on a local in-memory network with one simulated
  outage ([`RELEASE_READINESS.md`](RELEASE_READINESS.md#multi-participant-canton)).

Residual risks that remain after these controls:
- collusion or compromise of all four core signers;
- any one core participant can halt swaps, deposits, LP exits (paused pools included), pause
  and resume ([Unavailable or refusing signers](#unavailable-or-refusing-signers));
- permanent loss of a core signer freezes every pool it signs, with no recovery
  ([`PAUSE.md`](PAUSE.md#permanent-signer-loss));
- archival is destructive, and no on-ledger recovery exists
  ([Recovery after accidental archival](#recovery-after-accidental-archival));
- the custodian and both issuers see every LP identity and share amount;
- a finalized charter has no expiry, so its initial provider can initialize it at any later
  time and ratio;
- no independent audit, no custodian or issuer review of onboarding or pause, no operational
  procedures, migration rehearsed only with synthetic assets, and SDK digests that come from the
  publisher's registry rather than a signature.

These are why the deployment decision is **NO-GO**; the severities are in
[`RELEASE_READINESS.md`](RELEASE_READINESS.md#remaining-blockers).

## Legacy AMM

The legacy `canton-treasury-amm` package (`Pool`, `PoolSetup`, `LiquidityPosition`,
`SwapIntent`) is the Phase 0 MVP. Its weaknesses are characterized by passing tests, kept
unchanged so that any behavior change is noticed:

- **Operator reserve diversion.** The operator owns the reserve `Holding`s, and `TransferExact`
  is owner-controlled. The operator alone can therefore move a reserve outside any pool choice,
  which also freezes the pool (`Authorization:operatorAloneCanDivertReserveAndFreezePool`).
  Governance co-signs pool state but does not prevent this.
- **Issuer archival.** The issuer is the sole signatory of every `Holding`, so it can archive a
  reserve and freeze the pool (`Authorization:issuerCanArchiveReserveAndFreezePool`).
- **LP forgery.** The operator and governance together can create a `LiquidityPosition` with
  no deposit and redeem it against real reserves
  (`Authorization:colludingPoolSignatoriesCanRedeemForgedLiquidityPosition`).
- **Duplicate pool state.** The operator and governance together can create a second `Pool`
  over the same `PoolId` and reserve contract IDs, so two accounting states exist for one pool
  (`Pool:jointSignatoriesCanCreateCompetingPoolsOverSameReserves`). Nothing ties a pool state
  to a unique lineage or to exclusive use of its reserves.
- **Unaccounted LP burn.** `LiquidityPosition.BurnPosition` is provider-controlled and can be
  exercised outside `RemoveLiquidity`. The provider then forfeits its claim with no payout, and
  the pool's recorded `totalShares` no longer reconciles with outstanding positions
  (`Liquidity:directPositionBurnLeavesPoolSupplyUnchanged`). Legacy positions are signed by the
  operator and governance only, not by the provider.

The legacy model therefore trusts the operator as reserve custodian, trusts each issuer not to
archive reserves, and trusts the operator and governance not to collude. Secure V1 does not
change any of this for legacy contracts. A deployed legacy pool keeps these weaknesses until it
is drained (see [`MIGRATION.md`](MIGRATION.md)).

**Detection before migration (Stage 4.1).** The read-only lineage verifier
([`MIGRATION.md`](MIGRATION.md#lineage-verification)) reports each of these powers once it has
been used, if the auditor's and issuers' own participants still hold the history:
- diversion and issuer archival, as `RESERVE_DIVERTED` and `RESERVE_INACTIVE`;
- forgery and re-creation, as `LINEAGE_BROKEN`, `UNACCOUNTED_STATE` and
  `POSITION_OUTSIDE_LINEAGE`;
- duplicates, as `DUPLICATE_ACTIVE_STATE`;
- unaccounted burns, as `POSITION_OUTSIDE_LINEAGE` and `SUPPLY_MISMATCH`.

It prevents none of them and restores nothing. It depends on an anchor recorded independently
at the pool's opening, on readers that report honestly, and on retention back to the genesis.
A pool whose history is pruned or that no independent party observes cannot be verified.

`SecureV1Lifecycle:legacyOperatorDiversionCannotReachSecureReserves` shows that a legacy
diversion in the same ledger cannot touch Secure V1 reserves or pool state.

## Secure V1

- **Independently controlled custodian.** The custodian is a signatory of every charter, pool
  state, reserve and position. The `ensure` clauses require the custodian, the operator, both
  issuers and governance to be five distinct parties. Distinct party IDs do not prove
  independent organizations, keys or participants. That separation is operational (see
  [Signer separation](#signer-separation)). The multi-participant harness checks that each role
  is hosted only on its own participant (`MultiParticipant:mpVerifyHosting`).
- **Four-core authorization.** Charters, pool states and reserves are signed by the custodian,
  the operator and both issuers (the core); positions are also signed by their provider. No
  strict subset of the core can create, move or archive any of them.
  `SecureV1Attacks:everyPartialCoalitionIsRejected` covers all 31 non-empty subsets of the four
  core signers plus governance. Every subset is tested against the LP position and the trader's
  holding. The 29 subsets missing a core signer are also tested against archiving, replicating
  and minting pool contracts. The named coalitions are tested separately:
  operator alone, issuers, and operator with governance (`operatorAloneCannotDivertSecureReserves`,
  `issuersCannotArchiveOrSpendSecureReserves`, `operatorGovernanceCollusionCannotMoveReserves`).
  On Canton, each core party's participant must confirm every pool transaction.
- **Onboarding across participants.** A charter is created only by finalizing a
  `SecurePoolProposal` that carries all four core signatures, each added by that signer's own
  `ApprovePoolProposal` against the exact terms it reviewed (see [`ONBOARDING.md`](ONBOARDING.md)).
  The factory needs governance's acceptance of the operator's exact proposal, and each intent
  execution needs governance's approval of one intent with one holding. None of these templates
  holds or moves assets or LP shares, and the pool still starts only through `InitializePool`.
  `SecureV1Onboarding` tests finalization after every incomplete set of approvals, direct
  charter and proposal creation by each of the 29 privileged subsets missing a core signer,
  forged and misattributed approvals, 14 changed-term variants, replay, cancellation, expiry,
  competing proposals and second pools; the multi-participant run repeats the attacks across
  participants. A correct approval workflow does not reduce the full-core trust described
  below: the four core signers together can still create any charter directly.
- **Active protected reserve contracts.** Reserves are `SecureReserveHolding`s with no choices.
  They are archived and recreated only inside the pool's own choices. Before every operation,
  each choice fetches both referenced reserves and requires their amounts to equal the pool's
  recorded amounts (`amm/reserve-mismatch`). Stale disclosures and consumed contracts cannot
  stand in for live reserves (`staleDisclosuresCannotSettle`, `consumedContractsCannotBeReplayed`).
- **Authenticated pool and LP lineage.** Reserves, pool states and positions carry the pool's
  `SecureLineage` and its genesis, the consumed charter's contract ID. Each choice rejects
  reserves of another lineage or genesis, and `RemoveLiquidity` rejects positions of another
  pool (`reserveLineageMismatchIsRejected`, `positionGenesisMismatchIsRejected`). Counterfeit pools
  cannot drain real reserves (`counterfeitPoolsCannotDrainSecureReserves`), and forged positions
  cannot be issued or redeemed (`forgedLpPositionsCannotBeIssuedOrRedeemed`).
- **Authorized deposits and payouts.** A deposit must be the depositor's own holding of the
  reserve's instrument, with the reserve's auditors. It is moved by the depositor's own
  `TransferExact` inside the choice, so the core's authority cannot spend another party's
  holding (`foreignOrWrongHoldingsAreRejected`). Payouts are new holdings owned by the swapping
  trader or the redeeming provider only (`payoutsGoOnlyToTheTraderOrRedeemingLp`). A late
  failure rolls back the whole settlement (`lateFailureRollsBackTheWholeSettlement`).
- **Exact-input swaps.** A swap debits exactly the requested input and returns the change. It
  pays `floor(x·997·Rout / (Rin·1000 + x·997))` subject to the minimum output, the deadline, the
  expected pool version and the reserve cap. The legacy `validateSwap` is reused unchanged
  (`SecureV1Lifecycle:secureLifecycleMatchesLegacyStepByStep`).
- **Fee accounting.** The counters match the legacy pool. Each swap credits `ceil(3x/1000)` to
  the input instrument's counter, the counters saturate at the reserve cap, and liquidity changes
  leave them unchanged (`secureFeeRoundingMatchesLegacy`, `secureFeeCountersSaturateLikeLegacy`).
  `feeCountersStayExactAcrossMixedSwapsAndLiquidity` checks both counters after each of seven
  interleaved swaps, deposits and withdrawals by two providers.
- **Secure SwapIntent scope.** See [Secure SwapIntent scope](#secure-swapintent-scope).
- **Auditor and privacy model.** Pool auditors observe the charter, every pool state and every
  position. Holding auditors come from the deposits and see the reserves and every payout.
  Auditors have no authority (`secureAuditorsAndStakeholdersSeeWhatLegacyAuditorsSee`). Unlike
  the legacy pool, the custodian and both issuers see every pool state and position, including
  provider identities and share amounts. Traders need explicit disclosure of the pool and both
  reserves. In the multi-participant run, only the core, governance and auditor participants
  see the pool and reserves. The trader's participant sees none of them, and the provider's
  sees only its own positions. The trader's unspent holding is visible to the holding auditor
  and to no pool party (`MultiParticipant:mpScenarios`, scenario 9).
- **Residual full-core trust.** See [Residual trust](#residual-trust).

### Secure SwapIntent scope

An intent fixes the trader, pool lineage, genesis, direction, input amount, minimum output,
deadline and expected pool version. `Execute` needs both the operator and governance. It first
rejects any pool other than the intent's (`amm/pool-mismatch`), then calls the pool's
`SwapExactInput`, which pays only the intent's trader.

The executors also pass the input holding. The pool requires it to be the trader's own holding
of the input instrument, with the reserve's auditors and enough balance. Within that set the
executors choose, as in the legacy workflow.
`SecureV1SwapIntent:executorsChooseOnlyAmongTheTradersEligibleHoldings` demonstrates:
- a stablecoin holding is rejected for a Treasury intent (`amm/instrument-mismatch`);
- a holding with other auditors is rejected (`amm/incompatible-holdings`);
- a holding that is too small is rejected (`amm/insufficient-balance`), and the intent stays
  active;
- a larger eligible holding is accepted, exactly the intent's amount is debited, the change is
  returned to the trader and the payout matches the intent.

**Assessment: low severity, accepted, no API change.** The trader's economic outcome is
unchanged whichever eligible holding is chosen: the same debit, change returned to the trader,
and the same payout terms. What the executors control is which holding contract is split. That
can matter off-ledger, for example for lot or tax accounting, or if a specific holding is
earmarked. Binding the intent to one holding would change the `SubmitSwapIntent` and `Execute`
signatures, and that breaking API change is not justified at this severity.

The executors also choose when to execute before the deadline, and the order relative to other
transactions. That exposes the trader to price movement down to `minimumAmountOut`, as in the
legacy workflow. Any pool operation advances `stateVersion`, so an intent against an older
version fails and must be resubmitted.

## Source review

This and the two following source reviews are the project's own reviews. None of them is an
independent audit.

This review covered `SecureV1/Pool.daml` and `SecureV1/SwapIntent.daml` at package ID
`7f69816410e1c5e0…`, against the threat model above. No new critical, high or medium finding
was identified. The full core coalition remains trusted, and nothing here protects against it.

- **Nested exercise authorization.** User-facing choices (`InitializePool`, `SwapExactInput`,
  `AddLiquidity`, `RemoveLiquidity`) run with the core's authority plus the controller's. That
  authority is used only by the fixed bodies:
  - the depositor's `TransferExact`, which needs the depositor as owner;
  - archiving the moved part, which needs the issuer;
  - archiving and recreating the referenced reserves;
  - creating payouts for the controller;
  - archiving and recreating the controller's own position.

  No body exercises a choice on a contract ID it has not validated, and no body takes a
  party or contract argument that redirects value.
- **Signatory authority in user-facing choices.** `trader` and `provider` are choice arguments,
  but they are also the controllers. A party can only act as itself, and every deposit is checked
  against it (`amm/owner-mismatch`).
- **Input ownership and output beneficiary.** These are checked by `requireDeposit` and
  enforced by `TransferExact`. Payout recipients are the controller only.
- **Reserve lineage and amount reconciliation.** `validateSecurePool` checks lineage, genesis,
  instrument and the exact recorded amounts before any arithmetic.
- **LP entitlement authentication.** `RemoveLiquidity` checks the position's lineage, genesis and
  provider, the burn ≤ position bound and the locked-share guard. The position is archived with
  the provider's and the core's authority, and any remainder is recreated.
- **Fee reporting and orientation.** Treasury-to-stablecoin credits `treasuryFeeAmount`;
  stablecoin-to-Treasury credits `stableFeeAmount`. Add and remove copy both counters unchanged.
- **SwapIntent executor authority.** `Execute` carries only the trader's, the operator's and
  governance's authority, and pays only the trader. The holder-selection and timing residuals
  are described above.
- **Auditor visibility.** Deposits and reserves must have the same auditors, and every payout
  carries the reserve's auditors.
- **Genesis identity.** The charter is consumed by `InitializePool`, so each genesis yields
  exactly one initial state. Only the full core can create a second state for a genesis
  (`fullCoreCoalitionRemainsTrusted`).
- **Successor state.** Each choice archives the consumed pool state and creates exactly one
  successor with `stateVersion + 1`. Every transition in the tests checks this.
- **Consumed-contract replays and explicit disclosure.** A replay fails with `ContractNotFound`;
  on Canton, `CONTRACT_NOT_FOUND`. A stale disclosure cannot settle.
- **Contract creation and archival.** Reserves, pool states and positions are created only
  inside the charter and pool choices. Their implicit `Archive` needs all four core signers, plus
  the provider for positions.
- **Unexpected choices or withdrawal paths.** The compiled choice surface is exactly the reviewed
  list, and the `HoldingV1` interface instance adds no choices. The choice-surface script
  rejects an added reserve-release or position-burn choice and any new template (see
  [`RELEASE_READINESS.md`](RELEASE_READINESS.md#mutation-testing)).

Structural checks cannot prove that an existing choice body is safe. Any change to a body,
signatory or observer list, `ensure` clause or helper needs a semantic review against this
section.

### Onboarding source review (Stage 3.1)

This review covered `SecureV1/Onboarding.daml` at package ID `e4546c3f60ef59f0…`. `Pool.daml`
and `SwapIntent.daml` are unchanged from the review above. No critical, high or medium finding
was identified.

- **Whose authority each body carries.** `ApprovePoolProposal` runs with the current signers
  and the approver, and creates a successor signed by exactly those parties.
  `FinalizePoolProposal` runs with the proposal's signers, which must be exactly the four core
  signers, and creates only the charter. A charter create with any core signer missing fails
  authorization even if the finalization checks were removed (mutation testing confirms this).
  `AcceptFactoryProposal` runs with the operator and governance and creates only the factory.
  `ExecuteApprovedIntent` runs with governance and the operator and exercises only the approved
  intent's `Execute` with the approved holding.
- **No delegated authority beyond one action.** No choice takes a contract or command to run
  on the signers' behalf. Each body has a fixed effect, and the only party arguments are the
  approver or canceller, who must also be the controller.
- **Exact terms.** Every approval, finalization and factory acceptance compares the full terms
  record with the caller's expectation, so an approval cannot be moved to different parties,
  instruments, provider, auditors, reference or expiry.
- **Replay and duplicates.** Approvals, finalization, factory acceptance and execution
  approvals are consuming. Duplicate approvals fail the approver check. There is no global
  uniqueness: equal terms can create separate pools, and each stays bound to its own genesis.
- **Signers.** The proposal precondition admits only core signers and requires the operator,
  so governance or an outsider can never become a confirming party of a proposal, and requires
  independent roles, which the charter's precondition also enforces.
- **Governance.** Governance signs only the factory and execution approvals. It is never a
  signer of a proposal or a charter and gains no reserve authority.

### Pause source review (Stage 3.2)

This review covered `SecureV1/Pause.daml` and the `Pool.daml` refactor at package ID
`4abe290579f46ac9…` (version 0.2.0). `Onboarding.daml` and `SwapIntent.daml` are unchanged. No
critical, high or medium finding was identified.

- **Shared redemption.** `RemoveLiquidity` and `RemovePausedLiquidity` both run
  `validatePoolAccounts` and then `redeemPosition`. The checks happen in the same order as the
  Stage 3.1 `RemoveLiquidity`, so active and paused exits cannot diverge.
- **Whose authority each body carries.** `FinalizePause` and `FinalizeResume` run with the
  proposal's signers, which must equal the four core signers. Each fetches and validates the
  bound state and its reserves, archives that one state, and creates one counterpart with
  identical fields and the version plus one. Neither body creates or archives a reserve,
  position or holding. `RemovePausedLiquidity` pays only the controlling provider.
- **Exact terms and replay.** Approvals and finalizations compare the full terms record.
  Approvals, finalizations and cancellations are consuming. Finalization consumes the bound
  state, and every transition increases the version.
- **Signers.** The proposal precondition admits only distinct core signers from an
  independent lineage. Governance and the auditors are observers of the paused state only.

## Residual trust

### What the full core can do

Acting together, the custodian, the operator and both issuers can:
- create pool states, reserves and positions with no backing deposits;
- create a second active state for an existing genesis;
- mint themselves a position and redeem it from genuine reserves;
- co-burn a position together with its provider, which reconciliation reports as supply drift;
- archive the reserves, the pool state and the charter;
- pause or resume a pool directly, without a proposal, and archive a paused state with its
  reserves.

`SecureV1Attacks:fullCoreCoalitionRemainsTrusted` and
`SecureV1Pause:fullCoreCoalitionRemainsTrustedWhilePaused` demonstrate each of these. Even then, two
things stay out of reach: the core cannot spend a trader's holding without the trader, and it
cannot redeem a position beyond the supply minus the locked share.

### Destroyable assets and archivable contracts

The full core can archive every `SecureReserveHolding`, `SecurePool`, `SecurePausedPool` and
`SecurePoolCharter`.
Together with the provider, it can also archive any `SecureLiquidityPosition`. Archiving a
reserve destroys its on-ledger value and freezes the pool, because every later choice fails to
fetch the reserve. Each issuer alone can also archive any ordinary `Holding` of its
instrument, including swap payouts and LP withdrawals once they are paid out. That is the
existing legacy token model, which Secure V1 does not change.

### Recovery after accidental archival

No on-ledger recovery choice exists. If a reserve or pool state is archived, the only
restoration is for the full core to recreate the archived reserve and pool contracts with the
same lineage and genesis. The amounts must be reconciled from the last committed transaction
before the archival. Positions still reference the same genesis, so they would remain
redeemable. This is an off-ledger procedure that requires unanimity. It is not implemented or
tested as a procedure, and it relies on the same full-core trust that could forge state. It must
be reconciled independently against the transaction stream before any LP activity resumes.

### Unavailable or refusing signers

On Canton, every pool transaction needs a confirmation from each core party's participant.

- **One signer unavailable.** Swaps, deposits and withdrawals all halt. The multi-participant run
  disconnected the stablecoin issuer's participant. A swap then failed with
  `MEDIATOR_SAYS_TX_TIMED_OUT`, the pool state, reserves and the trader's input were unchanged,
  and a swap succeeded after reconnection (`MultiParticipant:mpOfflineSwap`,
  `mpReconnectedSwap`). Finalizing a fully approved pool proposal failed the same way during
  the outage, left the proposal unchanged, and succeeded after reconnection. That shows one
  participant, one outage and one recovery. It does not prove every outage or censorship
  property. With a paused pool, an LP withdrawal and the finalization of a fully approved
  resume failed the same way during a second outage and settled after reconnection
  (`mpOfflinePausedExit`, `mpResumeAfterOutage`): pause does not keep LP exits available when a
  signer is offline.
- **An issuer refuses to confirm.** The effect is the same as unavailability, but indefinite and
  selective: the issuer can block any swap or LP exit. LPs cannot exit without the issuer.
  There is no on-ledger remedy by design, because any bypass would let a smaller coalition move
  reserves. Remedies are contractual and off-ledger.
- **Custodian key loss.** The custodian signs every Secure V1 contract. If the custodian party
  can no longer be hosted or confirm, for example because its namespace key is lost with no
  rotation path, every pool it signs is permanently frozen. Mitigations are operational: an
  offline or HSM-held root namespace key, a tested key-rotation procedure, and possibly
  multi-hosting the custodian party. None of these was tested here.
- **Compromised operator.** The operator alone cannot move reserves, create state or forge
  positions. With governance it is still rejected (both tested on the IDE ledger and on the
  multi-participant network). A compromised operator can block pool transactions by not
  confirming, refuse or delay intent executions with governance, and exercise the executor
  discretion described above. Combined with the other three core signers, it is the full core.

### Unanimous operations

All four core signers must confirm:
- creating a charter, through the `SecurePoolProposal` workflow (see [`ONBOARDING.md`](ONBOARDING.md));
- every `InitializePool`, `SwapExactInput`, `AddLiquidity`, `RemoveLiquidity` and intent `Execute`;
- every pause and resume, through `SecurePauseProposal` and `SecureResumeProposal` (see
  [`PAUSE.md`](PAUSE.md)), and every `RemovePausedLiquidity`;
- every archive of a reserve, pool state, paused state or charter.

Archiving a position additionally needs its provider.

### Signer separation

The four core parties and governance must be operated by separate organizations. Each needs its
own participant, namespace keys and administrators, with no shared operator access, because a
shared participant or key collapses the coalition the design relies on. The ledger only checks
that the party IDs differ. The multi-participant harness hosts each role on its own participant
and asserts that through the participants' own party lists. Production hosting must be verified
the same way before go-live. Independent hosting makes each onboarding approval a separate
decision, but it does not prevent the organizations from colluding, and it does not protect
against a compromised key or participant of any signer.

### Emergency stop and recovery design

Since Stage 3.2, Secure V1 has a reversible pause (`CantonTreasuryAmm.SecureV1.Pause`; see
[`PAUSE.md`](PAUSE.md)):
- **Pause.** A `SecurePauseProposal` collects all four core signatures, one participant at a
  time. It is bound to the lineage, the genesis, the exact active state, its version and an
  expiry. Finalizing it archives that state and creates a `SecurePausedPool` with identical
  reserves, amounts, supply, locked share, fee counters and auditors, and the version plus one.
  `SecureResumeProposal` reverses this in the same way.
- **While paused.** The paused template has no swap, deposit or intent path. Its only economic
  choice, `RemovePausedLiquidity`, is the LP's own exit and runs the same validation and
  redemption code as `RemoveLiquidity`. No withdrawal by any core member, no sweep and no
  recipient argument exist.
- **Authority.** No strict subset of the core, and not governance, can pause, resume or act on
  a paused pool's reserves. A full-core pause adds no power the full core lacked, and it
  replaces the destructive freeze of full-core archival with a reversible stop.
- **What pause does not do.**
  - It does not help when a core signer is unavailable or refusing: paused exits, pause and
    resume all need every core participant (shown on the multi-participant network).
  - It cannot restore an archived reserve or pool state.
  - Full-core archival remains destructive and is not a safe stop.
- **Permanent signer loss.** This freezes the pool for good. The off-ledger recovery decisions
  are listed in [`PAUSE.md`](PAUSE.md#permanent-signer-loss). None is implemented, and none is
  authorized.

A single-party emergency pause was not added. It would give that party a griefing tool and
would still not let LPs exit without every core signer.

## Compatibility

- **Ordinary Holding inputs and payouts.** Deposits are the AMM's own ordinary `Holding`s, as in
  the legacy pool. Payouts and change are ordinary `Holding`s owned by the trader or provider,
  with the reserve's auditors. Existing wallets that read `Holding` see them as before.
- **Custom protected reserves.** Reserves are `SecureReserveHolding`s, signed by the core, which
  only Secure V1 pool choices can change. They are not ordinary holdings. An ordinary `Holding`
  cannot be a protected reserve, because its issuer alone can archive it and its owner alone can
  move it.
- **HoldingV1 view.** `SecureReserveHolding` implements `Splice.Api.Token.HoldingV1.Holding` as
  an informational view. The view reports the custodian as owner, the exact amount, and a lock
  held by the core with the context "AMM pool reserve; moves only through pool settlement". The
  interface declares no choices, so the view adds no movement path.
- **No arbitrary Token Standard reserve interoperability.** The following are unsupported as
  reserves or deposits: third-party `HoldingV1` implementations, transfer instructions and
  factories, allocations, registry choice contexts, locked holdings, multi-input settlement and
  mixed V1/V2 assets.
- **Required issuer cooperation.** Each issuer must adopt Secure V1, sign every charter and
  confirm every pool transaction through its participant. An issuer's participant must host the
  issuer party and vet the Secure V1 package. Without that cooperation, no Secure V1 pool can
  exist for its instrument.

## Deployment readiness

Secure V1 is **not ready for deployment**. The verified tests, CI execution status, Canton
coverage, packaging, migration, privacy and operational requirements, and the remaining
blockers are recorded in [`RELEASE_READINESS.md`](RELEASE_READINESS.md).
