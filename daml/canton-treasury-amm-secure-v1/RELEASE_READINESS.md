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

**Stage 3.3.** No deployable source changed. The legacy package is still `d8cadd3c…` (DAR
SHA-256 `42d50138…`), Secure V1 0.2.0 is still `4abe2905…`, and the live-reserve prototype's source is
unchanged (ID `aa060cbc…`, first recorded here). Only the tests package (`canton-treasury-amm-tests` 0.1.0, now `6b4e1ab1…`)
changed; it is never deployed. `check-packages.sh` now also pins the two vendored Token
Standard DARs by package ID.

**Stage 4.1.** No deployable source changed. The legacy package (`d8cadd3c…`, DAR SHA-256
`42d50138…`), Secure V1 0.2.0 (`4abe2905…`, DAR SHA-256 `3d1d0442…`) and the live-reserve
prototype (`aa060cbc…`) are unchanged. The new `LegacyLineage` test module changes only the tests
package, now `69af2248…` (DAR SHA-256 `92aaa43a…`), which is never deployed.

**External coordination still required.**
- Every participant hosting a core party, governance, an auditor, a trader or a provider must
  upload and vet the Secure V1 DAR. The legacy package stays vetted.
- Each issuer must agree to adopt and co-sign Secure V1.
- Nothing migrates automatically; see [`MIGRATION.md`](MIGRATION.md).

## CI

`.github/workflows/secure-v1-validation.yml` runs on every push and pull request on
`ubuntu-24.04`. It has `contents: read` permission only, no secrets, persisted credentials
disabled and actions pinned by commit SHA. Its steps:

1. `scripts/check-dpm-installer.sh`: negative tests of the SDK installer (below).
2. `scripts/install-dpm-verified.sh 3.5.5`: download the SDK archive for the runner's platform
   and install it only if its size and SHA-256 match the pins.
3. Print the toolchain versions, and fail if any `daml.yaml` is not pinned to 3.5.5.
4. `dpm build --all --no-cache`.
5. `dpm damlc lint` in all four packages. Lint exits non-zero on any hint.
6. `scripts/run-tests-strict.sh`. This runs `dpm test` and fails on any failure. It also fails
   if the set of passing tests differs from the `Script` values declared in the sources, so a
   skipped, renamed-away or missing test fails.
7. `scripts/run-tests-strict.sh` on `Test/Migration.daml` alone, the migration rehearsal.
8. `scripts/check-prototype-choice-surface.sh`, the template inventories and choice surfaces.
9. `scripts/check-packages.sh`: package IDs, dependencies, the vendored Token Standard DAR IDs
   and the upgrade check.
10. Record the SHA-256 of every built and vendored DAR in the logs artifact.
11. `python3 -m py_compile` on `verify-legacy-lineage.py` and `check-legacy-lineage.py`.
12. `scripts/run-multi-participant.sh`, including the migration rehearsal and the legacy
    lineage checks.
13. Upload the test and Canton logs and the DAR digests as an artifact, also on failure.

No step uses `|| true`, `continue-on-error` or skipped tests.

**SDK supply chain (Stage 3.3).** Until Stage 3.2, CI pinned the SHA-256 of
`get.digitalasset.com/install/install.sh`. That script downloads
`dpm-VERSION-OS-ARCH.tar.gz` from Digital Asset's Artifact Registry
(`projects/da-images/locations/europe/repositories/public-generic`, package `dpm-sdk`), extracts
it and runs `dpm bootstrap` without verifying the archive. `install-dpm-verified.sh` performs
the same steps, with these differences:
- Only SDK 3.5.5 is accepted. There is no "latest" lookup.
- The platform is detected explicitly. Only `linux-amd64`, `linux-arm64`, `darwin-amd64` and
  `darwin-arm64` have pins; any other operating system or architecture is refused.
- The archive's byte size and SHA-256 must equal the pins before anything is extracted or run.
  A missing checksum tool, a failed download or a missing archive also stop the install.

The pinned digests are the SHA256 values that the registry's files API records for each
3.5.5 file (created 2026-08-12). The linux-amd64 archive used by CI and the darwin-arm64
archive were downloaded in full, and both match their recorded size and digest. The digests
come from the publisher's own registry, the same origin as the download. They are not an
independent signature, and none was found. The installer script itself is no longer used.

`check-dpm-installer.sh` runs these negative tests, each of which must fail with its specific
reason and run nothing:
- a wrong, `latest`, empty or missing version;
- an architecture with no pin (through a fake `uname`);
- a platform override outside verify-only mode;
- a missing archive;
- a truncated archive;
- a same-size archive whose `bin/dpm` would leave a marker if run.

A control step first shows that this fake archive does run when nothing verifies it. With the
real archive as an argument, the script also checks that the archive verifies, that another
platform's pin rejects it, and that a copy with one flipped byte is refused. On macOS, a full
verified install from the darwin-arm64 archive into an empty home installed SDK 3.5.5 with
Canton 3.5.12.

`dpm bootstrap` installs the components bundled in the verified archive. Components `dpm`
might fetch later from its OCI registry are addressed by digest in that registry but are not
pinned here. The bootstrap was not run with networking disabled.

**Local validation.**
- The workflow parses as YAML (Ruby's standard YAML library) with `contents: read`, one job
  and the steps above. Each `run:` block, extracted from the parsed YAML, passes `shellcheck`,
  as does every script.
- Each script was run locally and also made to fail on purpose (see
  [Mutation testing](#mutation-testing)).
- No step contains `|| true` or a `latest` version.

**Remote execution (recorded after Stage 4.1).** The workflow has run on GitHub Actions for the
pushes of `c4de013`, `5f6cb43`, `13e2e12` and `e8da9ea`, and every run succeeded; `fb84f4a` has
no run of its own. The run for
`e8da9ea` passed every step above on `ubuntu-24.04` in about 13 minutes, of which the
multi-participant step took about 9, within the 60-minute timeout. That verifies the Linux
install path, the runner's memory for nine participants and the run time. It is evidence that
the committed source builds and passes these checks on a hosted runner with in-memory nodes. It
says nothing about a production topology, and it is not an audit.

**CI blockers and gaps.**
- **`actionlint` unavailable.** It is not installed locally, and installing it would add an
  unreviewed tool, so the workflow's static validation is incomplete.
- **Digest provenance.** The SDK digests are the publisher registry's own records, not a
  signature.

## Multi-participant Canton

**Result: PASS on a local network with eight independently hosted role participants**, plus
a ninth participant for the migration rehearsal's second LP. This covers the scenarios below on
one synchronizer. It is not evidence about production topology,
networking, key management or other outage modes.

- **Toolchain.** Canton open source 3.5.12 (protocol versions 34 and 35), run from the SDK 3.5.5
  jar under `~/.dpm/cache/components/canton-open-source/3.5.12`. Daml Script from the SDK.
  OpenJDK 21. The run records these in `versions.txt`, together with the SHA-256 of the test,
  legacy and Secure V1 DARs.
- **Topology** (`daml/canton-treasury-amm-tests/multi-participant/canton.conf`):
  - one sequencer and one mediator on the `amm` synchronizer;
  - eight participants named `custodian`, `operator`, `governance`, `treasury_issuer`,
    `stable_issuer`, `trader`, `provider` and `auditor`, and `second_provider` for the
    migration rehearsal;
  - in-memory storage throughout, with local ports 15001–15093 only;
  - on the auditor participant only, `init.ledger-api.max-deduplication-duration = 10s`, so
    that the lineage check can prune within a run.

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
| `mpMigrationAllocate` | A second LP is allocated on `second_provider`, which every participant then knows. It is hosted there and nowhere else, read from each participant's own party list. |
| `mpMigrationRehearsal` | Scenario A of [`MIGRATION.md`](MIGRATION.md#rehearsal), with the same amounts, each role submitting from its own participant. The legacy pool is set up through the test-only `LegacyPoolSetupProposal` (proposed by the operator, accepted by governance), initialized by the provider and joined by the second LP, and the trader swaps both ways. The auditor and the issuers reconcile the snapshot. Each LP exits and receives exactly its claim, and a replayed exit fails on the consumed state with the snapshot unchanged. The Secure V1 charter is onboarded on the four core participants, initialized from the first LP's proceeds (supply 7,071,091) and joined with the second's (707,108 shares). A swap (1,000 → 1,988) and a withdrawal (353,554 → 250,385 / 499,231) settle. The completion check reports no blocker, and an expectation one share off is reported. Instrument totals are unchanged throughout. |
| `mpLineageScenarios` (`CantonTreasuryAmm.Test.LegacyLineage`) and `check-legacy-lineage.py` | Twelve legacy pools with synthetic instruments, one per lineage scenario, each role on its own participant ([`MIGRATION.md`](MIGRATION.md#rehearsal)). The read-only verifier is run against each, with each party read on its own participant's JSON API, and every verdict, exit code and reason code is checked: 24 checks. The auditor's participant is then pruned past the genuine pool's genesis, and that pool gives INCOMPLETE EVIDENCE (`HISTORY_PRUNED`). The faithful re-creation and the reconciled forgery both pass the snapshot procedure in the phase and are BLOCKED by the verifier. |

The disconnection is done through the issuer participant's admin API, on the script's own local
network only. It demonstrates one outage of one confirming participant and its recovery. It
does not establish censorship resistance or any other outage behavior.

**Onboarding (Stage 3.1).** Stage 2.3 found that there was no production onboarding workflow and
used test-only templates in the tests package. Those templates are removed. Every
multi-signatory step in the harness now uses the production templates in
`CantonTreasuryAmm.SecureV1.Onboarding`; see [`ONBOARDING.md`](ONBOARDING.md). The test-only
templates in `MultiParticipant` are `GovernanceProxy`, an attack fixture for scenario 8, and
`LegacyPoolSetupProposal`, which sets up the legacy pool for the migration rehearsal because
legacy has no onboarding workflow.

**Warnings in a passing run.** `canton.log` contains no ERROR lines and exactly four WARN
lines, all from the stablecoin issuer's `TransactionProcessor`: "Response message for request …
timed out". Two come from the first outage (the swap and the charter finalization) and two from
the paused-pool outage (the exit and the resume finalization). In the final Stage 3.3 run,
which took about 4 minutes 15 seconds, every phase passed, including both migration phases, with
the same four WARN lines and no ERROR line. The final Stage 4.1 run, which adds the lineage
scenarios, the 24 verifier checks and the auditor pruning, took about 6 minutes and produced the
same four WARN lines and no ERROR line. After
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

**Stage 3.3.** These were applied one at a time: the rehearsal mutations to
`MigrationRehearsal.daml`, run with `dpm test` on `Migration.daml`; the installer mutations to
`install-dpm-verified.sh`, run with `check-dpm-installer.sh`. Each was reverted, and both files'
SHA-256 matched the originals afterwards. Every mutant compiled, so each kill is a failing test.

| Mutation | Caught by |
| --- | --- |
| An inactive legacy reserve is accepted | `divertedLegacyReserveBlocksMigration` |
| The legacy supply reconciliation always passes | `tamperedLegacyStateBlocksMigration` |
| The first of several legacy pool states is used | `tamperedLegacyStateBlocksMigration` |
| The legacy reserve amount is not compared | `tamperedLegacyStateBlocksMigration` |
| The legacy reserve owner is not compared | Survived at first; killed by `tamperedLegacyStateBlocksMigration` after adding a pool state whose Treasury reserve is another party's holding of the recorded amount |
| An exit may reduce another LP's claim | **Survived.** The legacy pool rounds every payout down, so no reachable state reduces another claim; the check is defensive |
| An active Secure V1 state is accepted next to a paused one | **Survived, equivalent.** Pause consumes the active state, so the two never coexist, and a paused state alone is still reported |
| Instrument totals are not compared | `reconciliationMismatchBlocksCompletion` |
| Outstanding legacy positions do not block completion | `partialMigrationKeepsTheRemainingLegacyClaim` |
| Secure V1 positions are not compared | `reconciliationMismatchBlocksCompletion` |
| The installer skips the SHA-256 comparison | "modified archive installs nothing" (the fake `bin/dpm` ran) and "real archive with one flipped byte" |
| The installer accepts any version | "wrong version", "latest version", "empty version" |
| The archive is extracted and bootstrapped before verification | "truncated archive" and "modified archive installs nothing" (content ran) |
| The platform override works outside verify-only mode | "platform override outside verification" |
| The darwin-arm64 pin is off by one hex digit | "real archive verifies" (locally, with the real archive). On CI, the same error in the linux-amd64 pin fails the install step |

**Stage 4.1.** Each mutation was applied alone to `verify-legacy-lineage.py` and checked with
`check-legacy-lineage.py` against a live local network running `mpLineageScenarios`. The
pruning mutation was checked after a real prune. Each was reverted, and both scripts' SHA-256
matched the originals afterwards. A kill means at least one check got a different verdict, exit
code or reason set. Where the verdict itself did not change, another check still refused the
pool, and the table says so.

| Mutation | Caught by |
| --- | --- |
| INCOMPLETE EVIDENCE findings ignored by the verdict | 6 checks; each would have reported VERIFIED |
| Non-transition choices accepted as lineage steps | **Survived, equivalent.** Legacy `Pool` has no consuming choices besides the three transitions and `Archive`, and `Archive` creates no successor, so the successor check reports the same `LINEAGE_BROKEN` |
| The anchor need not come from `Initialize` | The two re-creation anchors (verdict held by `ANCHOR_CONFLICT`) and, decisively, the version-0 re-creation of the genesis. Before that scenario was added, no check depended on this alone |
| Operator and governance count as independent attestors | Operator-attested anchor (`ANCHOR_PROVENANCE` missing; the verdict stays INCOMPLETE EVIDENCE because no independent stakeholder attests) |
| Reserve consumption outside the lineage not checked | Reserve diversion (verdict held by `RESERVE_INACTIVE`) |
| Current reserve activeness not checked | Reserve diversion |
| Position creation outside the lineage not checked | Forged position (verdict held by `LINEAGE_BROKEN`) |
| Position consumption outside a withdrawal not checked | Survived at first, because a partial burn also creates a remainder outside the lineage; killed after adding the standalone burn of a whole position |
| Reader hosting not checked | Auditor read through the trader's participant |
| `requireComplete` ignored | Partial migration with completion required, which would have reported VERIFIED |
| Pool states outside the lineage not reported | 4 checks; the duplicate active state would have reported VERIFIED |
| Supply reconciliation removed | Both standalone burns |
| Snapshot not required in the lineage | Snapshot from another pool's history (the verifier then fails closed on the missing index) |
| History read from offset 0 despite pruning | Pruned genuine pool. Canton itself refuses the read (`PARTICIPANT_PRUNED_DATA_ACCESSED`), so the verdict stays INCOMPLETE EVIDENCE |

## Stage 3.3 security review

This was a focused, read-only review of the Secure V1 sources for what the migration relies on:
charter initialization from redeemed proceeds, later deposits, onboarding expiry, pause during
migration, and the reconciliation procedure. It is not an audit. It found no new critical, high
or medium issue in Secure V1. Findings:

| Severity | Finding |
| --- | --- |
| Medium (legacy, known) | The operator and governance can archive and re-create a legacy pool state unchanged, and the reconciliation cannot tell. Migration must check each state's transaction history ([`MIGRATION.md`](MIGRATION.md#stop-conditions)); this is the legacy forgery power in [`SECURITY.md`](SECURITY.md#legacy-amm). |
| Low | A finalized `SecurePoolCharter` has no expiry. Its initial provider can initialize it at any later time, at a ratio of its choosing. Withdrawing an unused charter needs all four core signers to archive it; it holds no value. Onboarding and initialization should be scheduled together. |
| Info | Reserve auditors come from the initial deposit's holdings, not the charter's `auditors`. Every later deposit must carry the same auditor set (`amm/incompatible-holdings`). Payouts from one legacy pool share that pool's reserve auditors, so its LPs' proceeds are compatible with each other. Proceeds from pools with different holding auditors are not. |
| Info | No transaction spans the migration; the atomic units and the off-ledger coordination are listed in [`MIGRATION.md`](MIGRATION.md#atomicity-and-coordination). |

## Deployment readiness

- **Verified tests.** The full Daml Script suite passes on the IDE ledger. Legacy
  characterization tests are unchanged and still pass.
- **CI execution status.** Implemented, validated locally, and passing on GitHub Actions for
  every push since the workflow was added, most recently for `e8da9ea` (see [CI](#ci)).
- **Real Canton participant coverage.**
  - Stage 2.2: four Secure V1 scripts on a single-participant Canton 3.5.12 sandbox.
  - Stage 2.3: a single-participant sandbox for package coexistence, plus the multi-participant
    run.
  - Stage 3.1: the multi-participant run above, with production onboarding.
  - Stage 3.2: the same run, extended with pause, paused exits during an outage, and resume.
  - Stage 3.3: the same run, extended with the migration rehearsal on a ninth participant.
  - Stage 4.1: the same run, extended with the legacy lineage scenarios, the verifier checks and
    real pruning of the auditor participant.
  - Every other test ran on the IDE ledger only.
- **Multi-participant verification.** PASS, locally, for the scenarios above. Not run on any
  production-like topology.
- **Packaging and coexistence.** Resolved by a separate package; verified locally.
- **Migration readiness.** The design ([`MIGRATION.md`](MIGRATION.md)) has been rehearsed with
  synthetic assets on the IDE ledger (scenarios A–H) and end to end on the local
  multi-participant network (scenario A). Its reconciliation procedure exists as test code,
  not as reviewed production tooling. The read-only lineage verifier has been exercised on the
  local multi-participant network only (Stage 4.1). No real inventory has been taken, and no LP or issuer has
  been consulted.
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
| Medium | `actionlint` has not been run. The SDK archive digests come from the publisher's registry, not from a signature. CI now passes on GitHub Actions, which does not change this decision. |
| Medium | Migration has been rehearsed only with synthetic assets on local networks. The lineage verifier exists and has been exercised there only. It is unreviewed and unaudited, and it relies on anchors that no real pool has recorded. Production JSON API authentication, reader retention and the readers' own participants are untested. There is no reviewed inventory tooling, no withdrawal-window procedure, no decision on legacy dust, and no LP or issuer communication. |
| Medium | Privacy sign-off for the issuers' and custodian's visibility is missing. |
| Low | Intent executors choose among the trader's eligible holdings and the execution timing (see [`SECURITY.md`](SECURITY.md#secure-swapintent-scope)). |
