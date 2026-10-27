# Secure V1 onboarding

How a Secure V1 pool, its swap-intent factory and each intent execution are authorized when
every signer is hosted on its own participant, using the templates in
`CantonTreasuryAmm.SecureV1.Onboarding`. This is a design and procedure description for review.
Secure V1 is not deployed, not audited and not authorized for deployment. No custodian or
issuer has reviewed or accepted this model, and nothing here is a command to run against a live
ledger.

## Why a workflow is needed

A `SecurePoolCharter` is signed by four parties: the custodian, the operator, the Treasury
issuer and the stablecoin issuer (the core). A Canton participant can submit only for parties it
hosts, so when the four are hosted independently, no single submission can create the charter.
Disclosing a contract to a submitter shares visibility, not authority, and a choice body carries
only its contract's signatories and its controllers. The workflow therefore collects the four
signatures on one contract, one participant at a time, and creates the charter only when that
contract carries all four.

## Parties

| Role | Onboarding responsibility |
| --- | --- |
| Operator | Proposes the pool terms and finalizes the proposal; proposes the intent factory; exercises approved intent executions. |
| Treasury issuer, stablecoin issuer | Each approves the exact terms naming its instrument. |
| Custodian | Approves the exact terms naming it as custodian. |
| Governance | Accepts the intent factory and approves each intent execution. Not a signer of the charter, and never a signer of a proposal. |
| Initial provider | Named in the terms. Initializes the pool from the charter with its own holdings. |
| Pool auditors | Named in the terms. Observe the charter and the pool; no authority. |
| Trader | Submits intents through the factory; owns the input holding. |

## Pool proposal

1. **Proposal.** The operator creates `SecurePoolProposal` with `SecurePoolTerms`: the
   `SecureLineage` (custodian, operator, governance, both instruments, charter reference), the
   initial provider, the pool auditors and an expiry time. Its template precondition requires
   independent roles and distinct instruments, the operator among the signers, and only core
   signers as signers. The operator is its only signer; the other core signers observe it.
2. **Approvals.** The Treasury issuer, the stablecoin issuer and the custodian each exercise
   `ApprovePoolProposal` from their own participant, naming themselves as `approver` and passing
   the complete terms they reviewed as `expectedTerms`. The choice fails with
   `amm/onboarding-terms` unless those terms equal the proposal's, field for field. It fails
   with `amm/onboarding-approver` if the approver is not a core signer or has already approved,
   and with `amm/deadline` after expiry. It archives the proposal and creates a successor with
   the same terms, signed by the previous signers plus the approver.
3. **Ordering.** Approvals can come in any order. Each approver needs the current proposal
   contract ID, which every core signer can see on its own participant because the core signers
   are observers. Each approval consumes the previous contract, so two signers approving the same
   contract concurrently cannot both succeed: one fails on the consumed contract and retries on
   the successor.
4. **Finalization.** The operator exercises `FinalizePoolProposal` with the expected terms. It
   fails with `amm/onboarding-terms` if they differ, `amm/onboarding-incomplete` unless the
   signers are exactly the four core signers, and `amm/deadline` after expiry. It archives the
   proposal and creates exactly one `SecurePoolCharter` with the proposed lineage, initial
   provider and auditors. It creates no reserve, pool state, position or holding.
5. **Initialization.** As before, the initial provider exercises the charter's
   `InitializePool` with its own Treasury and stablecoin holdings. That is the only way a pool
   state, its reserves and the first position are created. The charter is consumed.

**Failure and retry.** Every rejection leaves the proposal as it was. A failed approval can be
retried with corrected terms only if the proposal itself is right; a proposal with wrong terms
cannot be changed and must be cancelled and proposed again. A failed finalization because of a
missing approval is retried after that approval.

**Cancellation.** Any core signer, whether it has approved or not, can exercise
`CancelPoolProposal`. Governance and outsiders cannot (`amm/onboarding-approver`). Cancellation
creates nothing. A cancelled or finalized proposal cannot be approved, finalized or cancelled
again; any attempt fails on the consumed contract.

**Expiry.** Approvals and finalization fail after `expiresAt`. An expired proposal can still be
cancelled. Expiry is checked against ledger time.

## Uniqueness and separate pools

There is no contract key and no global uniqueness of terms or charter references. Two proposals
with equal terms that both finalize create two charters and, if both are initialized, two
separate pools. Each pool's reserves and positions are bound to its own genesis (the charter's
contract ID), so a second pool cannot use the first pool's reserves, positions or intents
(`amm/reserve-mismatch`, `amm/position`, `amm/pool-mismatch`). Signers who want one pool per
reference must check for an existing proposal or charter before approving.

## Intent factory and intent execution

- **Factory.** The operator creates `SecureSwapIntentFactoryProposal` with `SecureFactoryTerms`:
  lineage, genesis (the charter's contract ID), authorized traders and compliance observers.
  Governance exercises `AcceptFactoryProposal` with the expected terms, which creates exactly
  that `SecureSwapIntentFactory`. The operator or governance can cancel the proposal.
- **Execution.** `SecureSwapIntent.Execute` still needs both the operator and governance as
  controllers. Governance creates a `SecureSwapIntentExecutionApproval` naming the operator, one
  intent and one trader holding. The operator exercises `ExecuteApprovedIntent` with the
  trader's holding disclosed to it, which runs exactly that intent's `Execute` with that holding.
  The approval is consumed by the execution, so it authorizes one execution. The owner,
  instrument, auditor, balance, slippage, deadline and pool binding checks of `Execute` and
  `SwapExactInput` are unchanged; a holding the trader does not own fails with
  `amm/owner-mismatch`. The operator or governance can cancel an approval.
- **No API change.** `Execute` is unchanged. A deployment that hosts the operator and
  governance on one participant can still exercise it directly with both parties.

## Hosting, disclosure and visibility

- **Hosting.** Each core signer and governance should be hosted on a participant run by its own
  organization. Independent hosting is what makes each approval a separate decision. It does
  not prevent collusion among signers, and it does not protect against a signer's compromised
  keys or participant. Full-core collusion or compromise can still create any charter directly
  (see [`SECURITY.md`](SECURITY.md)).
- **Custodian independence.** The custodian must be a separate organization from the operator
  and governance, with its own participant and keys. The template precondition only checks that
  the parties differ; it cannot check who controls them.
- **Disclosure.** No disclosure is needed for the pool proposal: every core signer observes it.
  The factory proposal is visible to the operator and governance. Execution approvals are
  visible to the operator and governance; the trader's input holding must be disclosed to the
  operator for `ExecuteApprovedIntent`, as it is today for `Execute`.
- **Visibility.** Proposals and charters reveal the pool terms (all roles, both instruments,
  the initial provider and auditors) to every core signer. Governance, the provider and the
  auditors see the charter after finalization.

## Prerequisites

- **Package upload and vetting.** Every participant hosting a core signer, governance, the
  initial provider, a trader or an auditor must upload and vet the reviewed Secure V1 DAR
  (`canton-treasury-amm-secure-v1` 0.2.0, package ID in [`RELEASE_READINESS.md`](RELEASE_READINESS.md))
  and the legacy DAR it depends on. A participant that has not vetted it cannot confirm, and the
  step that needs it fails.
- **Synchronizer.** All participants are connected to the same synchronizer, and every party in
  the lineage is known to every core participant. The tested setup uses one synchronizer; no
  reassignment between synchronizers is involved or tested.
- **Instruments.** Each issuer's `TokenInstrument` exists, and the initial provider holds
  enough of each instrument, disclosed to the auditors named in the terms.

## An offline signer

Every step that consumes a proposal or creates a charter needs confirmation from the
participants of the proposal's signers. If one of them is offline, the step does not commit
(`MEDIATOR_SAYS_TX_TIMED_OUT` in the local multi-participant run) and nothing changes. The
same step succeeds after that participant reconnects. Signers that have not yet approved only
observe the proposal; whether an observer's participant must be online for a step is a Canton
confirmation-policy question that this repository does not test. An expired proposal must be
proposed again.

## Scope

In scope: the authorization of charter creation, factory creation and intent execution across
independently hosted participants, as implemented and tested in this repository. Out of scope:
fees, reserve design, pausing and recovery, migration, key custody, legal agreements between
the organizations, and any deployment. The tests for this workflow are in
`CantonTreasuryAmm.Test.SecureV1Onboarding` (IDE ledger) and
`CantonTreasuryAmm.Test.MultiParticipant` (local Canton network, see
[`RELEASE_READINESS.md`](RELEASE_READINESS.md#multi-participant-canton)).
