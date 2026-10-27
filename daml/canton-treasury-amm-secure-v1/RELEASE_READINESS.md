# Secure V1 release readiness

This document records what has been verified for Secure V1, how it was verified, and what
still blocks a deployment.

**Decision: NO-GO for deployment.** The blockers are listed in
[Remaining blockers](#remaining-blockers). Secure V1 has not been audited. Deployment and the
migration of legacy pools remain unauthorized.

## Packaging and coexistence

Stage 2.2 added the Secure V1 modules to `canton-treasury-amm` 0.1.0, which changed the package
ID (`003203d0…`) while keeping the deployed name and version. Canton refuses to vet two packages
with the same name and version. `dpm upgrade-check --both` on the deployed legacy DAR and the
Stage 2.2 DAR fails with `KNOWN_PACKAGE_VERSION`. On a participant that already vets the legacy
package, that DAR would be stored but not vetted, so its templates would be unusable.

Two options were evaluated:
- **A: a versioned successor (`canton-treasury-amm` 0.2.0).** This would make Secure V1 a Smart
  Contract Upgrade successor of the legacy package. Every participant vetting it would then
  accept 0.2.0 as an upgrade of legacy contracts. That claims a compatibility the design does
  not need and an upgrade path it does not offer (see [`MIGRATION.md`](MIGRATION.md)). It would
  also bind future legacy fixes to the Secure V1 release.
- **B: a separate package (chosen).** The legacy package is restored to its Phase 0 source.
  Secure V1 is `canton-treasury-amm-secure-v1` (0.1.0 until Stage 3.1, 0.2.0 since Stage 3.2) in its own directory, with a
  `data-dependencies` entry on the legacy DAR for the shared `Holding`, `Math`, `Errors`,
  `Types` and `validateSwap`. The one new error ID moved to `CantonTreasuryAmm.SecureV1.Errors`.

| Property | Evidence |
| --- | --- |
| Legacy package ID unchanged | `d8cadd3c038655678a71e052616b054a07ad53600e2feb719456f629c2772aa6` before and after; the DAR is byte-identical to the Phase 0 build (SHA-256 `42d50138…`) |
| Secure V1 identity | `canton-treasury-amm-secure-v1` 0.2.0, `4abe290579f46ac931b72106e64d99f5c659708d3636b2698d115609ad81a2a9` since Stage 3.2. Earlier builds, both 0.1.0: Stage 3.1 `e4546c3f60ef59f07edb4ad1c61676ed46fe66eb8c998a1277aa29bc43b958c8`, Stage 2.3 `7f69816410e1c5e0ea68f839999abdbebd6ea33fe3b05b5861d5c75ae99f20dc` |
| Dependencies resolve | The Secure V1 DAR depends on exactly the legacy `d8cadd3c…` and the two vendored Token Standard DARs; no `daml-script` |
| Coexistence | `dpm upgrade-check --both` passes for the legacy and Secure V1 DARs |
| Legacy independently addressable | On a local Canton 3.5.12 sandbox, both DARs were uploaded through the JSON API and both packages appear as vetted. A script created legacy contracts and Secure V1 contracts side by side, and the active contracts carry template IDs from their own package: legacy `Pool`, `Holding` and `TokenInstrument` under `d8cadd3c…`; `SecurePool` and `SecureReserveHolding` under `7f698164…` |
| Old tests preserved | Every Phase 0, Stage 1.x and Stage 2.1 test passes unchanged; only the tests package's DAR reference changed |

`scripts/check-packages.sh` enforces these identities and runs the upgrade check in CI. Any
change to either package's source, including a comment, changes its ID and fails that check
until it is reviewed.

**Stage 3.1 package ID change.** The onboarding module
(`CantonTreasuryAmm.SecureV1.Onboarding`) and its three error IDs changed the Secure V1 package
ID from `7f698164…` to `e4546c3f…`, still as `canton-treasury-amm-secure-v1` 0.1.0. The Pool and
SwapIntent sources are unchanged. Consequences:
- The legacy package is unaffected: it is still `d8cadd3c…`, and `dpm upgrade-check --both` on
  the legacy and new Secure V1 DARs passes.
- `dpm upgrade-check --both` on the Stage 2.3 Secure V1 DAR (rebuilt from commit `c4de013`,
  which reproduces `7f698164…`) and the new one fails with `KNOWN_PACKAGE_VERSION`: two packages
  with the same name and version. A participant that had vetted `7f698164…` would not vet the
  new package. That DAR was only ever uploaded to the local test networks of Stage 2.2 and 2.3,
  so the version stays 0.1.0, and the `7f698164…` DAR is superseded and must not be
  distributed.
- The Secure V1 sandbox coexistence evidence above (Stage 2.3) was recorded for `7f698164…` and
  has not been repeated for `e4546c3f…`.

**Stage 3.2 version bump.** The pause module (`CantonTreasuryAmm.SecureV1.Pause`), its three
error IDs and the shared redemption helper in `Pool.daml` changed the package ID again. Keeping
0.1.0 would have been a third package with the same name and version, so the version is now
**0.2.0** (`4abe2905…`). Evidence, all with SDK 3.5.5:
- **Earlier builds reproduced.** Rebuilding commit `fb84f4a` reproduces `e4546c3f…`, and
  rebuilding `c4de013` reproduces `7f698164…`.
- **Same-version conflict confirmed.** `dpm upgrade-check --both` on those two 0.1.0 DARs fails
  with `KNOWN_PACKAGE_VERSION`, which is why the version had to change.
- **Upgrade check passes.** `dpm upgrade-check --both` passes:
  - from `e4546c3f…` to 0.2.0, which "claims to upgrade" `e4546c3f…`;
  - from `7f698164…` to 0.2.0;
  - for the legacy DAR, `e4546c3f…` and 0.2.0 checked together.

  0.2.0 only adds modules, templates, data types and error IDs. Every existing template keeps
  its fields, signatories, observers and choice signatures.
- **Legacy unaffected.** The legacy package is still `d8cadd3c…`.

What this does not show:
- The check is type-level Smart Contract Upgrade compatibility only. It does not show that
  migrating contracts is safe, and no contracts were migrated.
- A participant vetting 0.2.0 would also let 0.2.0 code act on any 0.1.0 contracts. None exist
  outside discarded local test networks.
- Nothing was uploaded to a live participant. The superseded 0.1.0 DARs must not be
  distributed.
- The single-participant sandbox coexistence check was not repeated for 0.2.0. The
  multi-participant run below uploads the test DAR, which includes 0.2.0, and runs both
  packages side by side.

**External coordination still required.**
- Every participant hosting a core party, governance, an auditor, a trader or a provider must
  upload and vet the Secure V1 DAR. The legacy package stays vetted.
- Each issuer must agree to adopt and co-sign Secure V1.
- Nothing migrates automatically; see [`MIGRATION.md`](MIGRATION.md).

## CI

`.github/workflows/secure-v1-validation.yml` runs on every push and pull request on
`ubuntu-24.04`. It has `contents: read` permission only, no secrets, persisted credentials
disabled and actions pinned by commit SHA. Its steps:

1. Install `dpm` from `get.digitalasset.com`. The installer script's SHA-256 is checked
   before it runs, and it is invoked with the pinned SDK version 3.5.5.
2. Print the toolchain versions, and fail if any `daml.yaml` is not pinned to 3.5.5.
3. `dpm build --all --no-cache`.
4. `dpm damlc lint` in all four packages. Lint exits non-zero on any hint.
5. `scripts/run-tests-strict.sh`. This runs `dpm test` and fails on any failure. It also fails
   if the set of passing tests differs from the `Script` values declared in the sources, so a
   skipped, renamed-away or missing test fails.
6. `scripts/check-prototype-choice-surface.sh`, the template inventories and choice surfaces.
7. `scripts/check-packages.sh`.
8. `scripts/run-multi-participant.sh`.
9. Upload the test and Canton logs as an artifact, also on failure.

No step uses `|| true`, `continue-on-error` or skipped tests.

**Local validation.**
- The workflow parses as YAML with the expected permissions, shell and steps, and `shellcheck`
  passes on every script.
- Each script was run locally and also made to fail on purpose (see
  [Mutation testing](#mutation-testing)).
- The install step's exact mechanism was run on macOS into an isolated home directory: the
  checksum-verified installer with `3.5.5` installed `dpm` 1.0.21, `damlc` 3.5.2 and Canton
  3.5.12, the versions used throughout.

**CI blockers and gaps.**
- **Not run on GitHub.** The workflow has never executed remotely, so there is no remote CI
  result. The Linux install path, the runner's memory for eight participants, and the run time
  are unverified until it does.
- **SDK tarball not checksum-pinned.** The installer script is pinned by SHA-256, but it
  downloads the SDK tarball over HTTPS without verifying a checksum. Pinning the tarball needs
  its published digest, which could not be obtained in this stage.
- **`actionlint` unavailable.** It was not installed locally, so the workflow has not been
  linted beyond a YAML parse.

## Multi-participant Canton

**Result: PASS on a local network with eight independently hosted participants.** This
covers the scenarios below on one synchronizer. It is not evidence about production topology,
networking, key management or other outage modes.

- **Toolchain.** Canton open source 3.5.12 (protocol versions 34 and 35), run from the SDK 3.5.5
  jar under `~/.dpm/cache/components/canton-open-source/3.5.12`. Daml Script from the SDK.
  OpenJDK 21. The run records these in `versions.txt`, together with the SHA-256 of the test,
  legacy and Secure V1 DARs.
- **Topology** (`daml/canton-treasury-amm-tests/multi-participant/canton.conf`):
  - one sequencer and one mediator on the `amm` synchronizer;
  - eight participants named `custodian`, `operator`, `governance`, `treasury_issuer`,
    `stable_issuer`, `trader`, `provider` and `auditor`;
  - in-memory storage throughout, with local ports 15001–15083 only.

  `bootstrap.canton` connects every participant and uploads the test DAR. Each party is
  allocated on its own participant.
- **Command.** `bash daml/canton-treasury-amm-tests/scripts/run-multi-participant.sh`, after
  `dpm build --all`. Logs go to `AMM_MP_LOG_DIR`: `canton.log`, one log per phase, and the
  participant configurations used.

The script runs these phases in order, from `CantonTreasuryAmm.Test.MultiParticipant`:

| Phase | What it shows |
| --- | --- |
| `mpAllocate`, `mpVerifyHosting` | Each role is hosted only on its own participant, read from every participant's own party list, so independence is checked rather than inferred from distinct party names. |
| `mpSingleSubmissionCharter` | A single submission acting as all four core signers is refused (Daml Script: "All parties must be on the same participant"); the script asserts this failure. |
| `mpScenarios` 1–5 | The charter is created through the production `SecurePoolProposal`: the operator proposes, then the Treasury issuer, the stablecoin issuer and the custodian each approve on their own participant, and the operator finalizes; every core participant sees each successor with exactly the signatures so far. The factory is created through `SecureSwapIntentFactoryProposal` and the intent executed through `SecureSwapIntentExecutionApproval`. Then initialization (7,071,067 supply), a swap (1,000 → 1,993), a deposit (706,965 shares for 500,000 / 999,601), a withdrawal (353,482 shares → 249,999 / 499,799) and a swap-intent execution (2,000 → 997, change 3,000). Each is checked exactly against the pool, the reserves and the instrument totals. |
| `mpScenarios` 6–8 | Operator-only diversion, issuer-only archival (each issuer on its own participant) and operator-with-governance collusion through a governance-signed proxy are all rejected with `DAML_AUTHORIZATION_ERROR`. |
| `mpScenarios` 9–10 | Each participant sees exactly its role's contracts; a trader without disclosure cannot settle. A replay of consumed contracts is rejected. |
| `mpImpersonation` (scenario 11) | One participant submitting for core and issuer parties it does not host is rejected with `NO_SYNCHRONIZER_ON_WHICH_ALL_SUBMITTERS_CAN_SUBMIT`. |
| `mpOnboardingAttacks` | Onboarding attacks, each from the attacker's own participant, with every onboarding, pool and holding contract compared on the core participants before and after. Charter creation by the operator or custodian alone, a proposal created by governance, and a proposal carrying a forged issuer signature: `DAML_AUTHORIZATION_ERROR`. The operator approving as either issuer, governance approving as the custodian, and the custodian finalizing: `DAML_AUTHORIZATION_ERROR`. Governance approving as itself and a repeated approval: `amm/onboarding-approver`. Seven sets of different terms (provider, auditors, instrument symbol, instrument issuer, governance, operator, reference): `amm/onboarding-terms`. A replayed approval of a consumed proposal: `CONTRACT_NOT_FOUND`. Finalization without the stablecoin issuer or without the custodian: `amm/onboarding-incomplete`. Conflicting proposals: an approval or a finalization naming the other proposal's terms fails with `amm/onboarding-terms`. Cancelled proposals approved or finalized again, and a finalized proposal finalized or cancelled again: `CONTRACT_NOT_FOUND`. A second pool is then onboarded and initialized on the same instruments: the first pool's position fails on it with `amm/position`, a first-factory intent aimed at it fails with `amm/pool-mismatch`, and a swap on it leaves the first pool unchanged. Domain rejections appear in `canton.log` as `DAML_FAILURE` with the `amm/...` error ID. |
| `mpOfflineSwap` | With the stablecoin issuer's participant disconnected, a swap and the finalization of a proposal all four core signers have approved both fail with `MEDIATOR_SAYS_TX_TIMED_OUT`. The pool state, the reserves, the trader's input and the proposal are unchanged, and no charter exists for its terms. |
| `mpReconnectedSwap` | After reconnection, the same swap succeeds (1,000 → 1,993) and the same proposal finalizes into exactly its charter. |
| `mpPauseLifecycle` | Pause through `SecurePauseProposal` (see [`PAUSE.md`](PAUSE.md)). Rejected, each from the attacker's own participant: the operator approving as the Treasury issuer and a governance-created proposal claiming all four signatures (`DAML_AUTHORIZATION_ERROR`); governance approving and a repeated approval (`amm/lifecycle-approver`); an approval naming a wrong version (`amm/lifecycle-terms`); finalization with three approvals (`amm/lifecycle-incomplete`); a replayed approval (`CONTRACT_NOT_FOUND`). The four core signers then approve on their own participants and the pool pauses with every field carried over and the version plus one, as seen from every reading participant. While paused, a swap and a deposit fail on the consumed state (`CONTRACT_NOT_FOUND`) and on a coerced paused reference (`WronglyTypedContract`). The provider's partial exit settles exactly (1,000,000 shares → 707,248 / 1,413,932). |
| `mpOfflinePausedExit` | With the stablecoin issuer's participant disconnected, the provider's full exit from the paused pool and the finalization of a fully approved resume both fail with `MEDIATOR_SAYS_TX_TIMED_OUT`; the paused state, reserves, position and proposal are unchanged. Pause does not keep LP exits available when a core signer is offline. |
| `mpResumeAfterOutage` | After reconnection, the same exit settles (353,483 shares → 250,000 / 499,801). The resume approved for the replaced paused state fails with `CONTRACT_NOT_FOUND`; a fresh four-participant resume restores the pool exactly (4,293,756 / 8,584,083, supply 6,071,067). Governance and repeated approvals and a replayed finalization are rejected. A swap settles (1,000 → 1,992) and the pre-resume version is rejected (`amm/stale-state`). |

The disconnection is done through the issuer participant's admin API, on the script's own local
network only. It demonstrates one outage of one confirming participant and its recovery. It
does not establish censorship resistance or any other outage behavior.

**Onboarding (Stage 3.1).** Stage 2.3 found that there was no production onboarding workflow and
used test-only templates in the tests package. Those templates are removed. Every
multi-signatory step in the harness now uses the production templates in
`CantonTreasuryAmm.SecureV1.Onboarding`; see [`ONBOARDING.md`](ONBOARDING.md). The only test-only
template left in `MultiParticipant` is `GovernanceProxy`, an attack fixture for scenario 8.

**Warnings in a passing run.** `canton.log` contains no ERROR lines and exactly four WARN
lines, all from the stablecoin issuer's `TransactionProcessor`: "Response message for request …
timed out". Two come from the first outage (the swap and the charter finalization) and two from
the paused-pool outage (the exit and the resume finalization). In the Stage 3.2 run, which took
about 4 minutes, every phase passed. After
reconnection, the sequencer refuses the issuer's late confirmations with
`MAX_SEQUENCING_TIME_EXCEEDED`, which is logged at INFO. The expected
rejections in the other phases are logged at INFO. The daemon exits with status 143 when the
script stops it with `SIGTERM`, and the script treats that as a clean stop.

## Mutation testing

Each mutation was applied alone, run, and reverted, and the file checksums were confirmed
afterwards.

**Stage 2.2 count corrected.** The Stage 2.2 report said "12 of 12 behavioural mutations" and
"17 mutations", but its itemized list contained 13 behavioural mutations. The test logs confirm
13 distinct runs, all killed: m1–m6, m7a (fee orientation), m7b (floor rounding) and m8–m12.
Their failure counts were 3, 1, 1, 22, 1, 21, 21, 1, 1, 1, 1, 1 and 3 tests. With the five
structural mutations, all detected by the choice-surface script, that makes 18 mutations.

**Stage 2.3:**

| Mutation | Caught by |
| --- | --- |
| `AddLiquidity` resets the Treasury fee counter | `feeCountersStayExactAcrossMixedSwapsAndLiquidity` |
| `RemoveLiquidity` credits the stablecoin fee counter | `feeCountersStayExactAcrossMixedSwapsAndLiquidity` |
| Auditor check removed from deposits | `executorsChooseOnlyAmongTheTradersEligibleHoldings` |
| `Execute` swaps the chosen holding's full amount | `executorsChooseOnlyAmongTheTradersEligibleHoldings` |
| Trader hosted on the provider's participant | `mpVerifyHosting` |
| Disconnection of the issuer participant skipped | `mpOfflineSwap` (the swap unexpectedly succeeded) |
| A new template with no choices added to Secure V1 | Template inventory only; every choice-surface check still passed |
| `ReleaseReserve` added to `SecureReserveHolding` | Secure V1 choice surface |
| `BurnPosition` added to `SecureLiquidityPosition` | Secure V1 choice surface |
| A test that does not run (a stub declared but skipped) | `run-tests-strict.sh` |

**Stage 3.1** (each applied alone to `Onboarding.daml`, built, run through
`run-tests-strict.sh` and reverted; the file's SHA-256 matched the original afterwards):

| Mutation | Caught by |
| --- | --- |
| Finalization no longer requires the stablecoin issuer's approval | `finalizationNeedsEveryCoreApproval`, `competingProposalsAndSecondPoolsStayIsolated`; the charter create then fails with `AuthorizationError` instead of `amm/onboarding-incomplete` |
| Finalization no longer requires the custodian's approval | `finalizationNeedsEveryCoreApproval` |
| Approval skips the terms equality check | `approvalsBindTheExactTerms` |
| Finalization skips the terms equality check | `approvalsBindTheExactTerms`, `competingProposalsAndSecondPoolsStayIsolated` |
| Approval is non-consuming (reusable) | 3 onboarding tests and the Secure V1 choice surface |
| Execution approval is non-consuming (reusable) | `onboardingCreatesExactlyTheApprovedCharterAndPool`, `executionApprovalsAuthorizeExactlyOneExecution` |
| Finalization controlled by the custodian instead of the operator | all 9 onboarding tests |
| Approval ignores the stablecoin instrument in the terms | `approvalsBindTheExactTerms` |
| Proposal precondition drops "operator among the signers" | `approvalsCannotBeForgedOrGivenForOthers` |
| Proposal precondition drops "only core signers sign" | Survived at first; killed by `approvalsCannotBeForgedOrGivenForOthers` after adding proposals signed by the operator with governance or the provider |
| Proposal precondition drops role independence | Survived at first (the charter's own precondition still rejects it at finalization); killed by `approvalsCannotBeForgedOrGivenForOthers` after adding proposals with dependent roles |
| Factory acceptance skips the terms equality check | `factoryProposalsCreateOnlyTheAcceptedFactory` |
| Approval skips the expiry check | `expiredProposalsCannotBeApprovedOrFinalized` |

**Stage 3.2** (each applied alone to `Pause.daml` or `Pool.daml`, built, run through
`run-tests-strict.sh` and reverted; every source's SHA-256 matched the original afterwards):

| Mutation | Caught by |
| --- | --- |
| Finalization no longer requires all four approvals | `pauseNeedsEveryCoreSigner`, `resumeNeedsEveryCoreSigner`; the state archive then fails with `AuthorizationError` instead of `amm/lifecycle-incomplete` |
| Pause skips the version check | `lifecycleStatesCannotBeReplayed` |
| Pause does not increase the version | 13 of the 15 pause tests |
| Finalization skips the lineage and genesis check of the bound state | `lifecycleApprovalsAreBoundToOnePool` |
| Resume resets the Treasury fee counter | 7 pause tests, including `feeCountersSurvivePauseAndResume` |
| Approval skips the terms equality check | `lifecycleApprovalsAreBoundToOnePool` |
| Expiry check removed | `lifecycleApprovalsAreBoundToOnePool` |
| Finalizer no longer has to be a core signer | `resumeNeedsEveryCoreSigner` |
| Pause drops the pool auditors | 14 of the 15 pause tests |
| A paused exit does not increase the version | 5 pause tests, including `pausedPoolSettlesTwoProviderExitsExactly` |
| A repeated approval is accepted | `pauseNeedsEveryCoreSigner` |
| Resume skips the reserve validation | `foreignReservesCannotBackALifecycleTransition` |
| The shared redemption rounds the Treasury payout up | 11 tests across `SecureV1Lifecycle`, `SecureV1Attacks`, `SecureV1Onboarding` and `SecureV1Pause` |
| A no-op `AdminWithdraw` choice on `SecurePausedPool` | Secure V1 pause choice surface |
| A `CustodianOnlyWithdraw` template | Template inventory and the pause choice surface |

## Deployment readiness

- **Verified tests.** The full Daml Script suite passes on the IDE ledger. Legacy
  characterization tests are unchanged and still pass.
- **CI execution status.** Implemented and validated locally. It has not run on GitHub.
- **Real Canton participant coverage.**
  - Stage 2.2: four Secure V1 scripts on a single-participant Canton 3.5.12 sandbox.
  - Stage 2.3: a single-participant sandbox for package coexistence, plus the multi-participant
    run.
  - Stage 3.1: the multi-participant run above, with production onboarding.
  - Stage 3.2: the same run, extended with pause, paused exits during an outage, and resume.
  - Every other test ran on the IDE ledger only.
- **Multi-participant verification.** PASS, locally, for the scenarios above. Not run on any
  production-like topology.
- **Packaging and coexistence.** Resolved by a separate package; verified locally.
- **Migration readiness.** A design only ([`MIGRATION.md`](MIGRATION.md)), with no tooling and
  no rehearsal.
- **Privacy requirements.** The custodian and both issuers see every pool state and position,
  including LP identities and share amounts. This needs sign-off from every LP and the
  issuers.
- **Onboarding.** Implemented in the package and tested on the IDE ledger and the local
  multi-participant network. [`ONBOARDING.md`](ONBOARDING.md) describes the procedure. No
  custodian or issuer has reviewed or accepted it.
- **Pause.** Implemented in the package and tested on the IDE ledger and the local
  multi-participant network ([`PAUSE.md`](PAUSE.md)). It needs all four core signers, and an
  offline core signer blocks paused LP exits and resume.
- **Operational procedures.** None exist for signer separation, key custody, incident
  response, recovery after archival, when to pause, or permanent signer loss (see
  [`SECURITY.md`](SECURITY.md) and [`PAUSE.md`](PAUSE.md#permanent-signer-loss)).

### Remaining blockers

| Severity | Blocker |
| --- | --- |
| High (inherent) | The full core coalition is trusted: it can forge, drain, freeze or destroy a pool. It is a trusted-custody design that relies on independent operation of the four core signers. |
| High | The onboarding workflow exists in source but has not been reviewed or accepted by any custodian or issuer, has been run only on a local test network, and is not audited. |
| High | There is no recovery from permanent loss of a core signer: every pool it signs freezes for good, pause included. The off-ledger decisions in [`PAUSE.md`](PAUSE.md#permanent-signer-loss) are unmade, and no key-rotation or multi-hosting procedure has been tested. Full-core archival remains destructive. |
| High | The pause workflow has not been reviewed or accepted by any custodian or issuer, has been run only on a local test network, and is not audited. |
| High | No independent security audit has been done. |
| Medium | Any one core participant can halt every pool operation, including LP exits from a paused pool, and pause and resume themselves. |
| Medium | CI has never run remotely, and the SDK tarball is not checksum-pinned. |
| Medium | Migration tooling, a rehearsal, and LP and issuer communication do not exist. |
| Medium | Privacy sign-off for the issuers' and custodian's visibility is missing. |
| Low | Intent executors choose among the trader's eligible holdings and the execution timing (see [`SECURITY.md`](SECURITY.md#secure-swapintent-scope)). |
