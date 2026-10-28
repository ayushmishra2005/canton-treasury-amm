# Seven-minute project walkthrough

A spoken walkthrough of `canton-treasury-amm` for a technical interview or portfolio review.
Each section has a time box, what to show on screen, and a script of roughly 130 words per
minute. Every claim links to the document that holds its evidence. Nothing here adds to those
documents; if they disagree, they win.

**Status to state up front:** nothing is deployed or independently audited, and the documented
release decision for Secure V1 is **NO-GO**
([`RELEASE_READINESS.md`](../daml/canton-treasury-amm-secure-v1/RELEASE_READINESS.md)).

**Have open:** the [README architecture diagram](../README.md#architecture),
[`SecureV1/Pool.daml`](../daml/canton-treasury-amm-secure-v1/daml/CantonTreasuryAmm/SecureV1/Pool.daml),
the [trust-boundary summary](../daml/canton-treasury-amm-secure-v1/SECURITY.md#trust-boundaries-and-residual-risk-summary)
and the [remaining blockers](../daml/canton-treasury-amm-secure-v1/RELEASE_READINESS.md#remaining-blockers).

## Script

### 0:00–0:40 What it is

*Show: the README title and status line.*

This is a constant-product AMM, written in Daml for Canton, that swaps a tokenized U.S.
Treasury asset against a USD stablecoin. There are two deployable packages: the original MVP,
which I keep unchanged as a characterized baseline, and Secure V1, a separate package that
protects the pool reserves. Up front: nothing here is deployed or independently audited, and
the documented release decision is NO-GO. What I want to show is the design, the evidence
behind each claim, and exactly what is still trusted.

### 0:40–1:30 The AMM core

*Show: README, [Model](../README.md#model).*

Pricing is Uniswap V2's x times y equals k, with a 30 basis-point fee applied as 997 over
1000; the fee stays in the reserves for LPs. Rounding always favours the pool: payouts and
withdrawals round down, contributions round up. Wide arithmetic uses `Numeric 0`, and each
reserve is capped at 10¹⁷ atoms so no intermediate overflows. The first LP receives floor of the square root of x times y shares,
with one share atom locked forever and a minimum of 10⁶ to blunt first-depositor inflation.
Every operation consumes the pool contract and creates exactly one successor with a higher
version, so replays and stale operations fail.

### 1:30–2:40 The custody problem and the Secure V1 fix

*Show: [`SECURITY.md`, Legacy AMM](../daml/canton-treasury-amm-secure-v1/SECURITY.md#legacy-amm),
then `SecureReserveHolding` and `SecurePool` in `Pool.daml`.*

The MVP's weakness is custody. The operator owns the reserve holdings, and holdings are
owner-transferable, so the operator alone can drain a reserve and freeze the pool. Each issuer
can archive a reserve, and the operator with governance can forge LP positions or duplicate
pool state. Tests demonstrate each of those, so any behaviour change is noticed.

Secure V1 fixes this structurally. A reserve is a `SecureReserveHolding`, signed by the
custodian, the operator and both issuers, which I call the core, and it has no choices at all.
It changes only inside the pool's own swap and liquidity choices, which first check that both
reserves belong to this pool's lineage and genesis and hold exactly the recorded amounts.
Deposits move by the depositor's own transfer, payouts go only to the trader or the redeeming
LP, and LP positions are signed by the provider and the core.

### 2:40–3:40 Independent participants and onboarding

*Show: the diagram's participants and Onboarding box, then
[`ONBOARDING.md`](../daml/canton-treasury-amm-secure-v1/ONBOARDING.md).*

On Canton, a participant can only submit for parties it hosts, so four independently hosted
signers cannot create a four-signature charter in one command. The onboarding module solves
that. The operator proposes exact terms, the two issuers and the custodian each approve from
their own participant, and an approval fails unless the terms match field for field. The
operator finalizes only once all four have signed, and only then can the initial provider call
`InitializePool`. Governance never signs the pool: it accepts the swap-intent factory and
approves each intent execution, with no reserve authority. I ran this on a local Canton network
of nine participants, one per role plus a second LP, and checked from each participant's own
party list that every role is hosted only there.

### 3:40–4:30 Pause, resume and their limits

*Show: [`PAUSE.md`, Lifecycle](../daml/canton-treasury-amm-secure-v1/PAUSE.md#lifecycle).*

Pause is a separate template, `SecurePausedPool`, so "paused" cannot be a flag that some
choice forgets to check. Pausing needs all four core approvals and carries the reserves, supply
and fee counters over unchanged. A paused pool has no swap or deposit path, but LPs can still
exit through the same redemption code an active pool uses. Resume reverses it, and versions
keep increasing, so pre-pause intents never settle afterwards. The limit is that pause needs
every core signer. With the stablecoin issuer's participant disconnected, paused exits and
resume both timed out, and settled after reconnection. Pause is an operational stop, not
recovery.

### 4:30–5:30 Migration and lineage verification

*Show: the diagram's Migration box, then
[`MIGRATION.md`, Lineage verification](../daml/canton-treasury-amm-secure-v1/MIGRATION.md#lineage-verification).*

Legacy contracts cannot be upgraded into Secure V1, because the package and the signatories
differ, and copying a position would be forgery. So the design is that each LP exits through
the legacy pool's own `RemoveLiquidity` and deposits into a freshly onboarded Secure V1 pool.
But a legacy pool's balances can reconcile while its history is forged. So before any
migration, a read-only verifier walks the pool's history from an anchor the auditor recorded
independently when the pool opened, reading the auditor's and issuers' own participants. It
returns VERIFIED, BLOCKED or INCOMPLETE EVIDENCE, and is tested on twelve synthetic pools,
including forgeries and a real prune. VERIFIED is evidence for a human decision, not an
approval, and no migration is authorized.

### 5:30–6:20 How it is verified

*Show: the CI badge and the [workflow](../.github/workflows/secure-v1-validation.yml).*

Every security claim names a test. The Daml Script suite covers sixteen attack scenarios and
all 31 coalitions of the core plus governance, and a strict runner fails if any declared test
is skipped or missing. CI pins the template and choice surface and the package IDs, so adding
a withdraw choice, or even changing a comment, fails until it is reviewed. Each stage was also
mutation-tested, and the docs record which test killed each mutant. GitHub Actions runs all of
it, including the nine-participant network, with read-only permissions, pinned actions and a
hash-verified SDK, and it passes on the current commit. Those checks are change control, not a
semantic proof.

### 6:20–7:00 Trust boundaries, residual risk and NO-GO

*Show: the [trust-boundary summary](../daml/canton-treasury-amm-secure-v1/SECURITY.md#trust-boundaries-and-residual-risk-summary)
and the [remaining blockers](../daml/canton-treasury-amm-secure-v1/RELEASE_READINESS.md#remaining-blockers).*

What is still trusted: the four core signers together can forge, drain, freeze or destroy a
pool, so this is trusted custody, not trustless. Any one core participant can halt everything,
LP exits included, and losing one for good freezes its pools. The custodian and issuers see
every LP position. There has been no independent audit, and no real custodian or issuer has
reviewed onboarding or pause. That is why the decision is NO-GO, and closing it needs at least
an external audit, operational procedures and privacy sign-off.

## Likely questions

- **Why not a Smart Contract Upgrade from the legacy package?** An upgrade must keep the same
  package name, templates and signatories for existing contracts. Secure V1 has different
  templates and signatories, so no upgrade path exists, and claiming one would be misleading.
  As a separate package, the legacy DAR stays byte-identical and both can be vetted side by
  side ([`RELEASE_READINESS.md`](../daml/canton-treasury-amm-secure-v1/RELEASE_READINESS.md#packaging-and-coexistence)).
- **Why unanimity instead of a threshold?** Any path that lets fewer than four signers move a
  reserve lets that smaller coalition move it. The cost is liveness: one unavailable core
  participant halts the pool ([`PAUSE.md`](../daml/canton-treasury-amm-secure-v1/PAUSE.md#liveness-limits)).
- **Why no single-party emergency pause?** It would hand that party a griefing tool and would
  still not let LPs exit without every core signer.
- **Does the ledger prove the signers are independent?** No. It only checks that the five party
  IDs differ. The test network verifies hosting from each participant's own party list, and a
  production deployment would have to verify it the same way
  ([Signer separation](../daml/canton-treasury-amm-secure-v1/SECURITY.md#signer-separation)).
- **What do traders and outsiders see?** Nothing without explicit disclosure. A direct swap
  needs the pool and both reserves disclosed by a core party
  ([`SECURE_V1.md`](../daml/canton-treasury-amm-secure-v1/SECURE_V1.md#auditors-and-privacy)).
- **What if a reserve is archived?** Only the full core can archive it. That destroys its
  on-ledger value and freezes the pool, and there is no on-ledger recovery
  ([`SECURITY.md`](../daml/canton-treasury-amm-secure-v1/SECURITY.md#recovery-after-accidental-archival)).
- **What does the CI badge prove?** That the committed source builds, lints, passes the strict
  test run, keeps the reviewed choice surface and package IDs, and passes the local
  multi-participant scenarios on a hosted runner. It is not evidence of production readiness.
- **Which known issues are accepted?** Intent executors choose which eligible trader holding to
  spend and when to execute, and a finalized charter has no expiry
  ([`SECURITY.md`](../daml/canton-treasury-amm-secure-v1/SECURITY.md#secure-swapintent-scope),
  [`RELEASE_READINESS.md`](../daml/canton-treasury-amm-secure-v1/RELEASE_READINESS.md#stage-33-security-review)).

## Claims to avoid

These would be inaccurate:
- "audited", "production-ready", "deployed", or "tested on a production network";
- "trustless" or "non-custodial": the full core is trusted;
- "Token Standard compatible" without qualification: holdings implement the V1 `Holding`
  interface as a read-only view, and arbitrary Token Standard holdings are not accepted as
  reserves or deposits;
- "pause protects LPs when a signer is offline": it does not;
- "migration is supported": it is a design rehearsed with synthetic assets, and it is not
  authorized;
- "censorship-resistant": one outage of one participant was tested, nothing more.
