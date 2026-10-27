# Secure V1 pause, paused-pool LP exits and recovery limits

`CantonTreasuryAmm.SecureV1.Pause` adds a reversible pause to Secure V1 pools. A paused pool
cannot trade or take deposits. Its LPs can still exit through their authenticated positions on
exactly the same terms as an active pool's `RemoveLiquidity`. Pause and resume need all four
core signers, each approving from its own participant.

Pause is an operational stop. It is not a recovery mechanism. It does not help when a core
signer is unavailable, and it cannot restore a reserve or pool state that has been archived.
Nothing here is deployed or audited. Secure V1 remains **NO-GO** for deployment (see
[`RELEASE_READINESS.md`](RELEASE_READINESS.md)).

## Lifecycle

```
SecurePool (v)  --FinalizePause-->  SecurePausedPool (v+1)  --RemovePausedLiquidity-->  SecurePausedPool (v+2) ...
      ^                                                                                        |
      +-----------------------------------  FinalizeResume  ----------------------------------+
                                    SecurePool (w+1), from the paused state at w
```

- **Model.** The paused state is a separate template, `SecurePausedPool` (option A). It has
  exactly the fields of `SecurePool`, the same signatories (the core) and the same observers
  (governance and the pool auditors), and the same `ensure` clause. It records:
  - the lineage and the genesis;
  - both reserve contract IDs and their recorded amounts;
  - LP supply and the locked share;
  - both fee counters;
  - the auditors and the state version.

  The pause status is the template itself. There is no off-ledger flag and no status field
  that a choice could forget to check. `SecurePool`'s schema and choices are unchanged.
- **Versions.** Every transition consumes the state and creates exactly one successor with
  `stateVersion + 1`: pause, each paused withdrawal, and resume. Versions only increase across
  the lifecycle, so a version observed before a pause can never settle after a resume
  (`amm/stale-state`).
- **Transitions move nothing.** `FinalizePause` and `FinalizeResume` archive one state and
  create its counterpart with identical reserves (the same contract IDs, still active),
  amounts, supply, locked share, fee counters, lineage, genesis and auditors. No reserve,
  position or holding is created or archived, and no LP share is minted or burnt.

## Authority

| Step | Controller | Checks |
| --- | --- | --- |
| Propose (`create SecurePauseProposal` / `SecureResumeProposal`) | any one core signer, signing alone | `ensure`: every signer is a core signer, no duplicates, independent lineage |
| `ApprovePause` / `ApproveResume` | the approving core signer, on its own participant | the terms equal the approver's expected terms (`amm/lifecycle-terms`); the approver is a core signer that has not approved (`amm/lifecycle-approver`); not expired (`amm/deadline`) |
| `FinalizePause` / `FinalizeResume` | any core signer | terms equal (`amm/lifecycle-terms`); the finalizer is a core signer (`amm/lifecycle-approver`); all four core signers approved (`amm/lifecycle-incomplete`); not expired; the bound state is this lineage and genesis (`amm/pool-mismatch`); its version is the bound one (`amm/stale-state`); its reserves are this pool's live reserves with the recorded amounts (`amm/reserve-mismatch`) |
| `CancelPause` / `CancelResume` | any core signer | the canceller is a core signer; creates nothing |
| `RemovePausedLiquidity` | the position's provider | identical to `RemoveLiquidity` |

An approval binds the following terms:
- the lineage, which fixes the four core identities, governance, both instruments and the
  charter reference;
- the genesis;
- the exact state contract ID;
- the expected state version;
- an expiry.

An approval is the approver's own signature on a contract with those fixed terms. It cannot be
moved to another pool, another state or another version. Each approval consumes the previous
proposal contract, so it cannot be replayed. Finalization consumes the bound state, so a second
fully approved proposal for the same state then fails with `CONTRACT_NOT_FOUND`.

The design adds no unilateral power:
- No single party and no strict subset of the core can pause, resume, or create or archive a
  pool state, paused state or reserve.
- Finalizing is not a privilege, because the finalizer can only complete what all four signers
  approved.
- Governance and the auditors are never signers or controllers of any lifecycle contract. They
  have no reserve authority and cannot withdraw anyone's position.

A single-party emergency pause was not implemented. It would hand that party a griefing tool,
and it would still not let LPs exit without every core signer (see
[Liveness](#liveness-limits)). Adding one would change the trust model and needs an explicit
decision.

The four signers never need a shared participant. Each approval is a separate submission from
the approver's participant, and the finalizer's submission carries all four signatures through
the proposal's signatories. The multi-participant run asserts this on eight separately hosted
participants. The IDE tests also submit each approval as its own single-party submission.

## LP exits while paused

`RemovePausedLiquidity` runs the same code as `RemoveLiquidity`: `validatePoolAccounts`
followed by `redeemPosition` in `CantonTreasuryAmm.SecureV1.Pool`. The two choices differ only
in the template of the successor state they create. That gives them the same checks:
- the version check;
- the reserve binding check;
- the position's lineage and genesis;
- ownership by the provider;
- the amount and cap checks;
- the locked-share guard (`burn <= supply - locked`);
- floor rounding of both payouts;
- the zero-output and slippage checks;
- the `burn <= position` check;
- archiving the position and recreating any remainder;
- paying only the provider, with the reserve's auditors.

There is no separate burn path, no recipient argument and no withdrawal by any core signer.

## Choice surface

| Template | Choices |
| --- | --- |
| `SecurePausedPool` | `RemovePausedLiquidity` (provider); implicit `Archive` (all four core) |
| `SecurePauseProposal` | `ApprovePause`, `FinalizePause`, `CancelPause`; implicit `Archive` (its current signers) |
| `SecureResumeProposal` | `ApproveResume`, `FinalizeResume`, `CancelResume`; implicit `Archive` (its current signers) |

`scripts/check-prototype-choice-surface.sh` pins this list and the template inventory. The
package contains none of the following, and the surface check fails if any is added:
`AdminWithdraw`, `EmergencySweep`, `UnrestrictedRelease`, `IssuerOnlyRecovery`,
`OperatorOnlyRecovery`, `CustodianOnlyWithdraw`, an independent burn, or any reserve movement
outside `redeemPosition`, swaps and deposits.

## Invariants

These hold for every transition; the test helpers check each one exactly.
- **Reserves.** Both reserves are always the live reserves of the pool's lineage, genesis and
  instrument, at the recorded amounts. Pause and resume leave them untouched. A paused
  withdrawal reduces them by exactly the two payouts.
- **LP supply.** Supply equals the sum of the genesis's positions plus the locked share after
  every step. The locked share is never redeemed: a pool whose only LP has exited keeps 1 locked
  share backed by its remaining atoms (1 / 2 in the tests).
- **Fees.** Pause, paused withdrawals and resume carry both fee counters unchanged. The first
  swap after resume adds exactly its own fee. Fee value stays in the reserves, so paused LPs
  redeem their share of accrued fees.
- **Totals.** Instrument totals (ordinary holdings plus reserves) are unchanged by every
  transition and by every rejected attempt.
- **One state per genesis.** Exactly one active state or one paused state exists for a genesis.
  The full core coalition can break this (see [Trust](#full-core-trust)).

## Pending intents

A `SecureSwapIntent` names one exact `SecurePool` contract:
- **During the pause.** Pausing consumes that contract, so an intent submitted before the
  pause fails at `Execute` with `CONTRACT_NOT_FOUND`. An intent naming the paused state through
  a coerced `SecurePool` reference fails with `WronglyTypedContract`.
- **After resume.** Resume creates a new contract, so a pre-pause intent stays unusable.
- **Cancellation.** The trader can cancel any intent at any time.
- **New intents.** A new intent against the resumed state settles normally.

## Visibility

These were tested while active, paused and resumed:
- Governance and the auditors see the state, both reserves and every position.
- Each LP sees only its own position, and never the state or reserves; it settles with
  disclosures from a core party.
- The trader sees no state, reserve or position, and therefore no LP identity.
- Lifecycle proposals are visible to the four core signers only.
- A transition never changes the auditors.

## Multi-participant evidence

`scripts/run-multi-participant.sh` (see [`RELEASE_READINESS.md`](RELEASE_READINESS.md)) runs
three phases on the local eight-participant network.
- **`mpPauseLifecycle`.**
  - Wrong approvals, each from the attacker's own participant:
    - the operator approving as the Treasury issuer (`DAML_AUTHORIZATION_ERROR`);
    - governance approving (`amm/lifecycle-approver`);
    - approving a wrong version (`amm/lifecycle-terms`);
    - governance creating a proposal that claims all four signatures
      (`DAML_AUTHORIZATION_ERROR`);
    - finalizing with three approvals (`amm/lifecycle-incomplete`);
    - a replayed approval of a consumed proposal (`CONTRACT_NOT_FOUND`);
    - a repeated approval (`amm/lifecycle-approver`).
  - Independent approvals from the four core participants, followed by the pause. Every
    reading participant sees exactly the carried-over state.
  - While paused:
    - trading and deposits fail on the consumed active state (`CONTRACT_NOT_FOUND`) and on the
      coerced paused reference (`WronglyTypedContract`);
    - the provider's partial withdrawal settles exactly (1,000,000 shares for
      707,248 / 1,413,932).
- **`mpOfflinePausedExit`.** With the stablecoin issuer's participant disconnected, the
  provider's full withdrawal and the finalization of a fully approved resume both fail with
  `MEDIATOR_SAYS_TX_TIMED_OUT`. The paused state, the reserves, the position and the proposal
  are unchanged.
- **`mpResumeAfterOutage`.**
  - After reconnection, the same withdrawal settles (353,483 shares for 250,000 / 499,801).
  - The resume approved for the replaced paused state fails with `CONTRACT_NOT_FOUND`.
  - A fresh resume from four participants restores the pool with every field carried over.
    Governance and repeated approvals are rejected, as is a replayed finalization.
  - A swap settles on the resumed pool (1,000 → 1,992), and the pre-resume version is rejected
    (`amm/stale-state`).

## Liveness limits

- **An unavailable or refusing core signer blocks LP exits.** Every paused withdrawal re-signs
  the reserves, so it needs every core participant's confirmation, as an active withdrawal
  does. The offline phase above shows this. Pause is not a solution to signer unavailability,
  and no recovery bypass exists, by design: any path that lets fewer than four signers move a
  reserve would let that smaller coalition move it.
- **An unavailable signer also blocks pause and resume.** Finalization needs its
  confirmation. In the offline phase, a resume that all four signers had approved before the
  outage could not be finalized during it.
- **Racing with trading.** A pause is bound to one exact state contract and version. Any
  settlement in between consumes that state and voids the proposal (`CONTRACT_NOT_FOUND`), so
  the signers must re-propose for the current state. On a busy pool this needs coordination,
  for example the operator refraining from intent executions while approvals are collected.
  The binding is deliberate: an approval never applies to a state the signer did not see.
- **Expiry.** Proposals expire. An expired proposal must be cancelled and re-proposed.

## Package compatibility

Pause is released as `canton-treasury-amm-secure-v1` **0.2.0**. The legacy package
(`canton-treasury-amm` 0.1.0, `d8cadd3c…`) is unchanged.
- **Why not 0.1.0.** The new modules change the package ID. Canton refuses to vet two packages
  with the same name and version (`KNOWN_PACKAGE_VERSION`, reproduced between the two earlier
  0.1.0 builds), so keeping 0.1.0 would be a silent identity conflict.
- **Why a successor rather than a new name.** 0.2.0 adds templates, choices, data types and
  error IDs. It leaves every 0.1.0 template's fields, signatories, observers and choice
  signatures unchanged. `dpm upgrade-check --both` (SDK 3.5.5) passes from both earlier builds:
  - from the Stage 3.1 0.1.0 (`e4546c3f…`, rebuilt from commit `fb84f4a`);
  - from the Stage 2.3 0.1.0 (`7f698164…`, rebuilt from commit `c4de013`);
  - and with the legacy package, the Stage 3.1 build and 0.2.0 checked together.
- **What that does and does not show.** The upgrade check is a type-level compatibility check.
  It does not prove that contract migration is safe, and coexistence on a participant is not
  schema-upgrade safety. A participant vetting 0.2.0 would let 0.2.0 code exercise 0.1.0
  contracts, including pausing a 0.1.0 pool. No 0.1.0 contracts exist outside discarded local
  test networks. No migration is implemented, and nothing was uploaded to any live participant.

## Permanent signer loss

The full core signs every pool state, reserve and position, and Canton needs each signer's
participant to confirm. If one core signer is permanently lost, every pool it signs is frozen
on-ledger for good. The ways this happens include:
- the party's namespace key is lost with no rotation path;
- the organization ceases to exist;
- the signer refuses forever.

In that state:
- no choice can run, pause and resume included;
- the implicit `Archive` cannot run either, because it needs every signatory;
- the remaining three signers cannot act at all.

Nothing in this package changes that, and it must not, because any on-ledger path for fewer
than four signers is a path for those signers to move reserves.

Not implemented and not authorized: trustless key recovery, replacing the custodian,
withdrawals without an issuer, seizure, reissuance, and migration.

Recovery from permanent loss is an off-ledger procedure, and every step is a human decision:
1. **Declare the loss.** Who may declare a signer permanently lost, on what evidence (key
   ceremony records, legal notice, a time limit), and how the other organizations and the LPs
   verify the declaration. Temporary unavailability is waited out; only a declared permanent
   loss proceeds.
2. **Fix the cut-off.** Choose the last committed transaction that defines the frozen pool.
   That pins its state, both reserves, every position and the fee counters, reconciled
   independently against the transaction stream by each remaining organization.
3. **Compute entitlements.** Each LP is entitled pro rata to its shares of the frozen reserves.
   Decide the treatment of the locked share and of rounding.
4. **Void the frozen claims.** The frozen reserves and positions stay on-ledger forever. Each
   issuer must decide, legally and operationally, that its frozen reserve value is void and will
   never be honoured twice. A lost issuer is a different case: its instrument itself is
   affected, and only that issuer's successor organization can decide what its tokens mean.
5. **Reissue and re-establish.** The issuers decide whether to reissue LP entitlements as
   ordinary holdings off the reconciled snapshot. They choose a replacement organization for the
   lost role and decide whether to charter a new pool through the normal onboarding workflow.
6. **Communicate.** Notify the LPs, auditors and traders, including how pending intents and
   in-flight payouts are handled.

Mitigations before go-live are operational: offline or HSM-held root namespace keys, a tested
key-rotation procedure and multi-hosting of each core party. None was tested here.

## Full-core trust

Acting together, the four core signers remain trusted, paused or not. They can do the following
without any proposal:
- archive the active state and create a paused state directly, or the reverse;
- create states or positions without backing;
- archive a paused state together with both reserves
  (`SecureV1Pause:fullCoreCoalitionRemainsTrustedWhilePaused`).

Archiving destroys the reserves' on-ledger value and strands every LP position. It is
destructive, not a safe stop. Pause does not recover from it: nothing in the package can restore
an archived reserve, and the only restoration is the full-core off-ledger procedure described
in [`SECURITY.md`](SECURITY.md#recovery-after-accidental-archival). Even the full core cannot
redeem a position without its provider, or pay a redemption to anyone else.

## Tests

`CantonTreasuryAmm.Test.SecureV1Pause` (15 tests) covers the following:
- the two-LP lifecycle: fees, pause, a partial and a full exit, the remaining claim, the
  locked-share guard, resume and a swap;
- a full exit down to the locked share;
- trading and deposits while paused;
- every partial coalition for pause and resume;
- replay and stale versions;
- cross-pool approvals and expiry;
- forged and Phase 0 positions;
- Stage 1.1 custody paths;
- foreign reserves;
- fees across the lifecycle;
- intents;
- late-failure rollback for pause, withdrawal and resume;
- full-core trust;
- per-role visibility.

Every rejection asserts the error class and compares the full ledger snapshot, including paused
states and lifecycle proposals.
