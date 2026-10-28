# Secure V1 pool (protected live reserves)

`CantonTreasuryAmm.SecureV1.Pool` and `CantonTreasuryAmm.SecureV1.SwapIntent` are a parallel
implementation of the AMM in which pool reserves are protected contracts rather than
operator-owned holdings. They carry the Stage 2.1 "model B" prototype into a separate,
release-checked package; that does not make them production-ready. They live
in their own package, `canton-treasury-amm-secure-v1` 0.2.0, which data-depends on the legacy
`canton-treasury-amm` 0.1.0 DAR (package ID `d8cadd3c…`) for `Holding`, `Math`, `Errors`,
`Types` and `Pool.validateSwap`. The legacy package is byte-identical to its Phase 0 build. Its
`Pool`, `LiquidityPosition` and `SwapIntent` templates remain the legacy MVP model, which is not
a secure reserve model.

Nothing here is deployed, audited or deployment-ready, and no migration of existing contracts is
implemented. Related documents in this package:
- [`SECURITY.md`](SECURITY.md): the legacy and Secure V1 security model, residual full-core
  trust, emergency operations and Token Standard compatibility.
- [`RELEASE_READINESS.md`](RELEASE_READINESS.md): packaging and coexistence, CI, multi-participant
  Canton evidence, mutation testing and deployment blockers.
- [`MIGRATION.md`](MIGRATION.md): the legacy-to-Secure V1 cutover design.
- [`ONBOARDING.md`](ONBOARDING.md): how charters, factories and intent executions are approved
  when every signer is hosted on its own participant.
- [`PAUSE.md`](PAUSE.md): pause and resume, LP exits while paused, liveness limits and permanent
  signer loss.

## Architecture and trust

| Template | Signatories | Observers | Choices |
| --- | --- | --- | --- |
| `SecurePoolCharter` | custodian, operator, Treasury issuer, stablecoin issuer (the core) | initial provider, governance, pool auditors | `InitializePool` (initial provider), single use |
| `SecurePool` | core | governance, pool auditors | `SwapExactInput` (trader), `AddLiquidity` (provider), `RemoveLiquidity` (provider) |
| `SecureReserveHolding` | core | governance, holding auditors | none; implements `HoldingV1.Holding` as a view |
| `SecureLiquidityPosition` | provider and core | governance, pool auditors | none |
| `SecureSwapIntentFactory` | operator, governance | authorized traders, compliance observers | `SubmitSwapIntent` (trader), non-consuming |
| `SecureSwapIntent` | trader, operator, governance | compliance observers | `Cancel` (trader), `Execute` (operator and governance) |
| `SecurePoolProposal` | the operator and each core signer that has approved | core | `ApprovePoolProposal` (the approving core signer), `FinalizePoolProposal` (operator), `CancelPoolProposal` (any core signer) |
| `SecureSwapIntentFactoryProposal` | operator | governance | `AcceptFactoryProposal` (governance), `CancelFactoryProposal` (operator or governance) |
| `SecureSwapIntentExecutionApproval` | governance | operator | `ExecuteApprovedIntent` (operator), `CancelExecutionApproval` (operator or governance) |
| `SecurePausedPool` | core | governance, pool auditors | `RemovePausedLiquidity` (provider) |
| `SecurePauseProposal` | each core signer that has approved | core | `ApprovePause` (the approving core signer), `FinalizePause` (any core signer, after all four approved), `CancelPause` (any core signer) |
| `SecureResumeProposal` | each core signer that has approved | core | `ApproveResume`, `FinalizeResume`, `CancelResume` (as for pause) |

The three proposal and approval templates of `CantonTreasuryAmm.SecureV1.Onboarding` only
collect approvals. They hold no assets, and each creates exactly one charter or factory, or
runs one intent's `Execute`. See [`ONBOARDING.md`](ONBOARDING.md).

`CantonTreasuryAmm.SecureV1.Pause` adds the paused state and its two proposals. A pause
proposal approved by all four core signers replaces the active `SecurePool` with a
`SecurePausedPool` carrying identical reserves, supply, locked share, fee counters and
auditors, and the version plus one. A resume proposal reverses it. The paused state has no swap
or deposit path; `RemovePausedLiquidity` runs the same redemption code as `RemoveLiquidity`.
See [`PAUSE.md`](PAUSE.md).

- **Reserves have no choices.** Every reserve is archived and recreated only inside a pool
  choice. Those choices run with the core's authority (the pool's signatories) and enforce the
  pool's accounting transition in their own fixed body. No template in the package exposes an
  externally exercisable choice that can pay out a reserve. Only the implicit `Archive` remains,
  and it needs all four core signers.
- **Binding.** Every reserve and position records the pool's `SecureLineage` and its genesis
  (the charter's contract ID). Before every operation, each pool choice checks that both
  referenced reserves are live reserves of its own lineage, genesis and instrument, and that
  their amounts equal the pool's recorded amounts (`amm/reserve-mismatch`). `RemoveLiquidity`
  accepts only positions of the same lineage and genesis (`amm/position`).
- **Deposits** must be the depositor's own `Holding` of the reserve's instrument
  (`amm/owner-mismatch`, `amm/instrument-mismatch`). They must also disclose to the same
  auditors as the reserve (`amm/incompatible-holdings`), the condition the legacy reserve
  `Merge` imposes. A deposit is moved to the custodian with the owner-controlled `TransferExact`
  and retired in the same transaction, so the custodian never keeps an ordinary holding.
- **Payouts** are new ordinary `Holding`s for the trader or the redeeming provider only, and
  they disclose to the reserve's auditors. A payout never empties a reserve.
- **Governance** observes everything but is not a signatory or controller of any reserve,
  pool state or position. It has no reserve-spending authority.
- **Trusted:** the full core coalition. Acting together, the four core signers can create pool
  states, reserves and positions without backing, and redeem them. They can archive reserves,
  which freezes the pool and destroys on-ledger value, and they can co-burn a position with its
  provider. The tests demonstrate each of these. Every smaller coalition, including the
  operator with governance, is rejected (all 31 subsets are tested).
- **Unsupported:** ordinary `Holding`s as reserves, arbitrary Token Standard holdings,
  third-party holding implementations, transfer instructions, allocations, and multi-input
  settlement. `SecureReserveHolding`'s standard view reports the custodian as owner, the exact
  amount, and a lock held by the core, with context "AMM pool reserve; moves only through pool
  settlement". That view is informational only.

## Operations

Pricing, rounding and limits reuse the production `Math`, `Errors` and `Pool.validateSwap` code
unchanged, as does the 30 bps fee (`997/1000`): payouts round down, contributions round up,
the initial supply is `floor(sqrt(x*y))` with one locked share and a 10^6 minimum, and the
reserve cap is 10^17 atoms.

- `InitializePool` is controlled by the initial provider and runs once per charter. It checks
  amounts, instruments, owners, balances and the minimum supply, then retires both deposits and
  returns their change. It creates both reserves (with the deposits' auditors), the pool state
  at version 0 with zero fee counters, and the provider's position.
- `SwapExactInput` works in either direction. The trader is the controller and must own the
  input holding; the payout goes to the trader. It checks the version, deadline, amounts, cap
  and slippage. The input is absorbed into its reserve and the output is paid from the other.
- `AddLiquidity` uses the legacy share formula and maxima, returns change, mints a new position
  and leaves the fee counters unchanged.
- `RemoveLiquidity` is controlled by the position's provider. It applies the locked-share guard
  and the burn ≤ position check, archives the position and creates any remainder, pays the
  provider, and leaves the fee counters unchanged. `RemovePausedLiquidity` on a paused pool
  shares this code.

Every operation, pause and resume included, consumes the pool state and creates exactly one
successor with `stateVersion + 1`.

## Fee accounting equivalence

`treasuryFeeAmount` and `stableFeeAmount` behave exactly as in the legacy `Pool`:
- They start at 0.
- A swap credits `ceil(input * 3 / 1000)` to the counter of the input instrument
  (Treasury-for-stablecoin credits `treasuryFeeAmount`; stablecoin-for-Treasury credits
  `stableFeeAmount`).
- They saturate at the reserve cap.
- Add and remove, pause, paused removal and resume leave them unchanged.
- Every successor carries them.

The tests compare the secure and legacy pools after every step, field by field: both reserves,
LP supply, the locked share, both counters and the version.

| Step on a 5,000,000 / 10,000,000 pool | Output | Treasury fee | Stablecoin fee |
| --- | --- | --- | --- |
| Initialize | 7,071,066 shares (supply 7,071,067) | 0 | 0 |
| Treasury → stablecoin 1,000 | 1,993 | 3 | 0 |
| Stablecoin → Treasury 5,000 | 2,492 | 3 | 15 |
| Add with maxima 500,000 / 1,000,000 | 706,894 shares for 499,701 / 1,000,000 | 3 | 15 |
| Remove 353,553 | 249,925 / 500,149 | 3 | 15 |
| Treasury → stablecoin 2,000 | 3,988 | 9 | 15 |
| Remove 353,341 | 249,870 / 499,660 | 9 | 15 |
| Remove 7,071,066 | 5,000,413 / 9,999,208 | 9 | 15 |

The sequence ends with reserves 1 / 2, supply 1 (the locked share) and version 7, identical to
the legacy pool. The rounding test covers inputs that are not multiples of 1000/3: inputs 1 and
333 (Treasury to stablecoin) each credit 1, and 1,001 (stablecoin to Treasury) credits 4. With
counters set to cap − 1, the input instrument's counter saturates and the other stays
unchanged, exactly as in the legacy pool.

## Auditors and privacy

- **Pool auditors** are listed on the charter. They observe the charter, every pool state and
  every position. Holding auditors come from the deposits: each reserve keeps its deposit's
  auditors, and every payout discloses to them, as transfers out of a legacy reserve do. With
  the standard fixtures, the auditor therefore sees the pool, both reserves, every position and
  every payout, the same set it sees for the legacy pool.
- **Auditors have no authority.** They are never signatories or controllers, and an auditor's
  archive or removal attempt fails with `AuthorizationError`.
- **Change from legacy:** the custodian and both issuers sign, and therefore see, every pool
  state, reserve and position (provider identities and share amounts included). In the legacy
  model, the issuers saw only the reserve holdings.
- Traders and outsiders see nothing without explicit disclosure. A direct swap, add or remove
  needs the pool and both reserves disclosed by a core party. `SecureSwapIntent` execution
  needs the trader's input holding disclosed to the operator and governance.

## Swap intents

The roles are the same as in the legacy workflow. The factory validates the trader, amounts,
cap and deadline. Only the trader cancels; only the operator and governance together execute.
An intent is bound to the factory's lineage and genesis: `Execute` rejects any other pool
(`amm/pool-mismatch`) and then runs the pool's `SwapExactInput` with the intent's trader,
direction, amount, minimum output, deadline and expected version, so the payout goes to the
trader.

Tested rejections:
- forged intents and forged executors (`AuthorizationError`);
- a coerced non-pool contract (`WronglyTypedContract`);
- replay of a consumed intent, and an intent whose pool state was replaced (`ContractNotFound`);
- expiry (`amm/deadline`, needs static time);
- slippage;
- foreign input (`amm/owner-mismatch`);
- single-controller execution and cancellation by anyone other than the trader
  (`AuthorizationError`).

As in the legacy workflow, the executors choose which of the trader's holdings to spend. It
must be the trader's own holding of the input instrument, with the reserve's auditors and enough
balance. Exactly the intent's input amount is debited and the change is returned to the trader.
`executorsChooseOnlyAmongTheTradersEligibleHoldings` pins this boundary. See
[`SECURITY.md`](SECURITY.md#secure-swapintent-scope) for why it is accepted as a low-severity
residual.

## Error classes in the tests

| Class | Meaning |
| --- | --- |
| `AuthorizationError` | Missing signatory or controller authority. Every such case discloses the touched contracts, so it is not a visibility failure. |
| `ContractNotFound` (consumed) | Replay of an archived contract. A Canton participant may report `LOCAL_VERDICT_INACTIVE_CONTRACTS` instead. |
| `ContractNotFound` (visibility) | An active contract the submitter cannot see. Asserted separately: stale reserve disclosures cannot stand in for the live reserves. |
| `WronglyTypedContract` | A Secure V1 contract passed to Stage 1.1 custody controls or to a legacy `Holding` choice. |
| `FailureStatusError` | A domain rejection with a stable `amm/...` error ID. Pause and resume add `amm/lifecycle-terms` (terms differ from the caller's), `amm/lifecycle-approver` (not a core signer, or already approved) and `amm/lifecycle-incomplete` (fewer than four approvals). |

On the local multi-participant Canton network, the same cases surface as Canton error codes:

| Canton code | Case |
| --- | --- |
| `DAML_AUTHORIZATION_ERROR` | Missing signatory or controller authority, detected while the submitting participant interprets the command. |
| `DAML_FAILURE` | A domain rejection; the `amm/...` error ID is in the error context, and Daml Script reports it as `FailureStatusError`. |
| `CONTRACT_NOT_FOUND` | Replay of a consumed contract. |
| `NO_SYNCHRONIZER_ON_WHICH_ALL_SUBMITTERS_CAN_SUBMIT` | A participant submitting for a party it does not host, including one that claims every core signer. |
| `MEDIATOR_SAYS_TX_TIMED_OUT` | A required confirming participant (a disconnected issuer's) did not respond; nothing is committed. |

## Tests

- `SecureV1Lifecycle`: legacy equivalence for initialization, the full sequence, rounding and
  saturation; exact fee counters across mixed swaps and liquidity changes; auditors and
  privacy; the auditor-compatibility check; legacy operator diversion leaving Secure V1
  reserves untouched.
- `SecureV1Attacks`: attacks 1–16 and all 31 partial coalitions.
- `SecureV1SwapIntent`: intents, including the executor's holder-selection boundary.
- `SecureV1Onboarding`: pool proposals, factory proposals and execution approvals, including
  every incomplete approval set, forged and misattributed approvals, changed terms, replay,
  cancellation, expiry, competing proposals and second pools.
- `SecureV1Pause`: pause, two-LP partial and full exits while paused, resume and the first
  swap after it; rejected trading, deposits and intents; every partial coalition; replay,
  cross-pool and expired approvals; forged positions; custody paths; foreign reserves; fee
  counters; late-failure rollback; full-core trust; visibility by role.
- `Migration`: the legacy-to-Secure V1 migration rehearsal with synthetic assets, scenarios A–H
  of [`MIGRATION.md`](MIGRATION.md#rehearsal), through the reconciliation procedure in
  `MigrationRehearsal`.
- `MultiParticipant`: the multi-participant Canton scenarios, including the migration
  rehearsal. Its scripts take arguments, so `dpm test` does not run them;
  `scripts/run-multi-participant.sh` runs them on a local network of eight role participants
  plus a second provider's (see [`RELEASE_READINESS.md`](RELEASE_READINESS.md)).

Shared invariant and settlement checks live in `SecureV1Support`; test-only adversary
templates are in `SecureV1Adversary`. After every transition, the checks cover:
- exactly one active or one paused state per genesis;
- reserve set and amounts;
- instrument totals (ordinary holdings plus reserves);
- the input instrument's fee counter, computed independently, with the other counter
  unchanged;
- raw and adjusted invariants;
- LP supply reconciliation and the locked share;
- archived predecessors and payout owners.

Rejections compare the full ledger snapshot before and after. The Phase 0 legacy
characterization tests and the Stage 1.1/2.1 prototype tests are kept as they were.

## Structural checks and semantic review

`scripts/check-prototype-choice-surface.sh` in the tests package lists the templates of every
deployable package and the choices of every reviewed template, and fails on any change. A new
template is caught even if it has no choices, as is an added reserve-release or position-burn
choice. `scripts/check-packages.sh` pins the Secure V1 package ID, so any source change,
including a comment, fails CI until it is reviewed.

These are change-control checks, not a semantic proof. They cannot show that the body of a
permitted choice is safe. Every change to a choice body, a signatory or observer list, an
`ensure` clause or a helper used by a choice needs a manual review against the threat model in
[`SECURITY.md`](SECURITY.md), plus the matching attack test, before the expected lists or the
pinned package ID are updated.

## Migration and deployment

No migration of a live pool is authorized, and Secure V1 is not deployment-ready.
[`MIGRATION.md`](MIGRATION.md) describes the cutover design: a parallel deployment in which each
LP redeems through the legacy `RemoveLiquidity` and deposits into Secure V1, with no conversion
of legacy contracts. It has been rehearsed with synthetic assets on the IDE ledger and on the
local multi-participant network only. Before a legacy pool migrates, its history is checked
against an independently recorded anchor by a read-only verifier
([`MIGRATION.md`](MIGRATION.md#lineage-verification)). The verifier is evidence for a human
decision, not an approval. [`RELEASE_READINESS.md`](RELEASE_READINESS.md) lists what is verified and
what still blocks a deployment.
