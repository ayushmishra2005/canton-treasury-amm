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
  Secure V1 is `canton-treasury-amm-secure-v1` 0.1.0 in its own directory, with a
  `data-dependencies` entry on the legacy DAR for the shared `Holding`, `Math`, `Errors`,
  `Types` and `validateSwap`. The one new error ID moved to `CantonTreasuryAmm.SecureV1.Errors`.

| Property | Evidence |
| --- | --- |
| Legacy package ID unchanged | `d8cadd3c038655678a71e052616b054a07ad53600e2feb719456f629c2772aa6` before and after; the DAR is byte-identical to the Phase 0 build (SHA-256 `42d50138…`) |
| Secure V1 identity | `canton-treasury-amm-secure-v1` 0.1.0, `7f69816410e1c5e0ea68f839999abdbebd6ea33fe3b05b5861d5c75ae99f20dc` |
| Dependencies resolve | The Secure V1 DAR depends on exactly the legacy `d8cadd3c…` and the two vendored Token Standard DARs; no `daml-script` |
| Coexistence | `dpm upgrade-check --both` passes for the legacy and Secure V1 DARs |
| Legacy independently addressable | On a local Canton 3.5.12 sandbox, both DARs were uploaded through the JSON API and both packages appear as vetted. A script created legacy contracts and Secure V1 contracts side by side, and the active contracts carry template IDs from their own package: legacy `Pool`, `Holding` and `TokenInstrument` under `d8cadd3c…`; `SecurePool` and `SecureReserveHolding` under `7f698164…` |
| Old tests preserved | Every Phase 0, Stage 1.x and Stage 2.1 test passes unchanged; only the tests package's DAR reference changed |

`scripts/check-packages.sh` enforces these identities and runs the upgrade check in CI. Any
change to either package's source, including a comment, changes its ID and fails that check
until it is reviewed.

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
| `mpScenarios` 1–5 | The charter is created through per-signer approvals, each on its own participant. Then initialization (7,071,067 supply), a swap (1,000 → 1,993), a deposit (706,965 shares for 500,000 / 999,601), a withdrawal (353,482 shares → 249,999 / 499,799) and a swap-intent execution (2,000 → 997, change 3,000). Each is checked exactly against the pool, the reserves and the instrument totals. |
| `mpScenarios` 6–8 | Operator-only diversion, issuer-only archival (each issuer on its own participant) and operator-with-governance collusion through a governance-signed proxy are all rejected with `DAML_AUTHORIZATION_ERROR`. |
| `mpScenarios` 9–10 | Each participant sees exactly its role's contracts; a trader without disclosure cannot settle. A replay of consumed contracts is rejected. |
| `mpImpersonation` (scenario 11) | One participant submitting for core and issuer parties it does not host is rejected with `NO_SYNCHRONIZER_ON_WHICH_ALL_SUBMITTERS_CAN_SUBMIT`. |
| `mpOfflineSwap` | With the stablecoin issuer's participant disconnected, a swap fails with `MEDIATOR_SAYS_TX_TIMED_OUT`. The pool state, the reserves and the trader's input are unchanged. |
| `mpReconnectedSwap` | After reconnection, the same swap succeeds (1,000 → 1,993). |

The disconnection is done through the issuer participant's admin API, on the script's own local
network only. It demonstrates one outage of one confirming participant and its recovery. It
does not establish censorship resistance or any other outage behavior.

**Finding: there is no production onboarding workflow.** A Secure V1 charter needs four
signatories, a factory two, and `Execute` two controllers. When those parties are hosted on
different participants, no single submission can supply their authority. The harness therefore
uses test-only templates in the tests package, which are not deployable:
- `CharterProposal`, which accumulates each core signer's approval;
- `FactoryProposal`;
- `ExecutionApproval`, in which governance pre-approves and the operator executes.

Production needs a reviewed equivalent of these workflows, or a multi-party submission
mechanism. That is a deployment blocker.

**Warnings in a passing run.** `canton.log` contains no ERROR lines and exactly one WARN. That
WARN comes from the stablecoin issuer's `TransactionProcessor` during the outage phase: "Response
message for request … timed out". After reconnection, the sequencer refuses the issuer's late
confirmation with `MAX_SEQUENCING_TIME_EXCEEDED`, which is logged at INFO. The expected
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

## Deployment readiness

- **Verified tests.** The full Daml Script suite passes on the IDE ledger. Legacy
  characterization tests are unchanged and still pass.
- **CI execution status.** Implemented and validated locally. It has not run on GitHub.
- **Real Canton participant coverage.**
  - Stage 2.2: four Secure V1 scripts on a single-participant Canton 3.5.12 sandbox.
  - Stage 2.3: a single-participant sandbox for package coexistence, plus the multi-participant
    run above.
  - Every other test ran on the IDE ledger only.
- **Multi-participant verification.** PASS, locally, for the scenarios above. Not run on any
  production-like topology.
- **Packaging and coexistence.** Resolved by a separate package; verified locally.
- **Migration readiness.** A design only ([`MIGRATION.md`](MIGRATION.md)), with no tooling and
  no rehearsal.
- **Privacy requirements.** The custodian and both issuers see every pool state and position,
  including LP identities and share amounts. This needs sign-off from every LP and the
  issuers.
- **Operational procedures.** None exist for signer separation, key custody, onboarding,
  incident response, recovery after archival or a pause (see [`SECURITY.md`](SECURITY.md)).

### Remaining blockers

| Severity | Blocker |
| --- | --- |
| High (inherent) | The full core coalition is trusted: it can forge, drain, freeze or destroy a pool. It is a trusted-custody design that relies on independent operation of the four core signers. |
| High | There is no production onboarding workflow for charters, factories and intent execution across participants. |
| High | There is no safe pause. Full-core archival is destructive. A non-destructive pause needs a schema change and its own review. |
| High | No independent security audit has been done. |
| Medium | Any one core participant can halt every pool operation, including LP exits. |
| Medium | CI has never run remotely, and the SDK tarball is not checksum-pinned. |
| Medium | Migration tooling, a rehearsal, and LP and issuer communication do not exist. |
| Medium | Privacy sign-off for the issuers' and custodian's visibility is missing. |
| Low | Intent executors choose among the trader's eligible holdings and the execution timing (see [`SECURITY.md`](SECURITY.md#secure-swapintent-scope)). |
