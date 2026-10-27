# Protected pool prototype: security model

Prototype only. `ProtectedPoolPrototype.daml` and `ProtectedCustodyPrototype.daml` live in the
test package, are exercised only by Daml Script tests, and are not part of the production AMM
(`canton-treasury-amm`). Nothing here authorizes production integration.

## Reserve backing

- **Deposit.** `InitializePool`, `AddLiquidity` and `SwapExactInput` consume the depositor's own
  production `Holding` (issuer-signed, owner-observed) and return any change as a new holding.
- **Backing obligation.** After a deposit the value exists only as `treasuryReserve` /
  `stableReserve` fields of the active `ProtectedPool` state. That state is signed by both
  instrument issuers (plus custodian and operator), so a reserve is an issuer-acknowledged
  liability recorded on the pool, not a separate holding contract.
- **Payout.** A swap output or LP withdrawal is a *new* `Holding` created with the issuer's
  authority, delegated through the pool's signatures. It is a re-issuance against the reserve
  decrement in the same transaction, not the transfer of a previously deposited contract.
- **Conservation.** For each instrument, `sum(holdings) + sum(pool reserves)` is unchanged by
  every prototype choice. Tests check this after every transition (`totalsOf` vs. issued amounts).
- **Out-of-pool issuance.** Issuers can still mint holdings at will (production `Token.daml`);
  the pool does not constrain or observe that. Reserves are only as sound as the issuer.
- **Issuer unavailability.** Every pool transition needs both issuers' hosting participants to
  confirm. If either is offline or refuses, the pool cannot swap, add or withdraw.
- **Versus the concrete-Holding model.** The production pool references deposited holdings; this
  prototype archives them and keeps balances in issuer-signed state. That closes the
  reserve-substitution and custodian-release paths, but it works only for instruments whose
  issuer co-signs the pool.

This design is issuer-mediated ledger accounting. It does not support arbitrary external
tokens, and issuer authorization is not evidence that any off-ledger asset backs a reserve.

## Identity and lineage

A signatory set is an authorization requirement, not an identifier. The full set (custodian,
operator, both issuers) can create any number of charters and pools with identical
`PoolLineage`. Each pool state and position carries `genesisCid`, the consumed `PoolCharter`'s
contract ID, and `RemoveLiquidity` requires the position's genesis to match the pool's. This
stops a position from one initialized pool being redeemed against another with equal lineage.
It does not give global uniqueness: the full signatory set can create a state or position
carrying any genesis ID. No same-coalition registry is used, because it would add no
independent protection.

## Permitted choice surface

The only choices (besides implicit `Archive`, which needs all signatories) are:

| Template | Choice | Controller |
| --- | --- | --- |
| `PoolCharter` | `InitializePool` (consuming) | charter's initial provider |
| `ProtectedPool` | `SwapExactInput` (consuming) | any trader, spending a holding it owns |
| `ProtectedPool` | `AddLiquidity` (consuming) | any provider, spending holdings it owns |
| `ProtectedPool` | `RemoveLiquidity` (consuming) | the position's provider |
| `PoolPosition` | none | — |

`CounterfeitPool` is a test-only adversary template.

Any added choice on `ProtectedPool` or `PoolCharter` runs with the custodian's, operator's and
both issuers' authority: it could create arbitrary issuer holdings (an admin withdrawal) or a
successor state with any reserves. An added choice on `PoolPosition` runs with its provider's
and the core set's authority and could burn shares outside `RemoveLiquidity`.

Review policy: any change to that list requires a security review of the new body's authority
and an updated expected list. `scripts/check-prototype-choice-surface.sh` (run after
`dpm build --all`) compares the compiled choice list from `dpm damlc inspect` against the
reviewed list and fails on any difference. It is a structural change detector: it cannot judge
whether a modified body of an *existing* choice is safe, and it does not inspect other modules
or packages.

Locked shares: `RemoveLiquidity` refuses burns that would reach `lockedShares`. Through the
permitted choices, positions always sum to `totalShares - lockedShares`, so the guard is only
reachable by a position the full core set created out of band; the successor's `ensure` then
backs it up by rejecting zero reserves.

## Trust limit

PROTECTED AGAINST (verified by tests on the IDE ledger; selected tests also on a Canton sandbox):
- any party spending, depositing or swapping a holding it does not own;
- any strict subset of the core signers creating, copying, archiving or forging a pool state,
  charter or position, or paying out through a counterfeit pool;
- Stage 1.1 custody controls (mandates, release requests, joint `Release`, coalition sweeps)
  reaching pool reserves;
- redeeming a position against a different initialized pool;
- stale versions, consumed states, consumed inputs and positions, and replays;
- expired deadlines (`now < deadline`), slippage, zero or invalid amounts and atom-cap overflow;
- partial settlement: every failing transaction rolls back completely.

NOT PROTECTED AGAINST:
- the full core set (custodian, operator, both issuers) acting together: it can create unbacked
  states, forge positions with a cooperating provider, copy genesis IDs, or archive (freeze)
  the pool;
- an issuer minting its instrument outside the pool;
- any signer's participant refusing or failing to confirm (liveness);
- changes to the choice surface or to existing choice bodies that skip review;
- off-ledger asset backing, which is out of scope.

## Privacy and liveness

Code-enforced:
- Pool states are signed by custodian, operator and both issuers, and observed by governance.
  All of them are informees of every swap, add and withdrawal, and see every trader and amount.
- Traders and new providers are not stakeholders of the pool state; they need its disclosure
  (`queryDisclosure` / `created_event_blob`) from a stakeholder.
- Positions are visible to their provider and the core signers only.

Deployment-dependent ([Privacy](https://archived.docs.digitalasset.com/overview/3.5/explanations/ledger-model/ledger-privacy.html),
[Explicit disclosure](https://archived.docs.digitalasset.com/build/3.5/sdlc-howtos/applications/develop/explicit-contract-disclosure.html),
[Multi-sig and confirmation](https://archived.docs.digitalasset.com/operate/3.5/howtos/operate/parties/multi-sig-in-canton.html)):
- Under signatory-based confirmation, each transition needs the participants hosting all four
  signers to confirm. A slow, offline or censoring issuer, custodian or operator halts the pool.
  Production pool states are signed by operator and governance; production swaps already need
  issuer confirmation for the holdings they move, but the custodian, and issuer confirmation of
  the pool state itself, are new dependencies.
- A stakeholder who withholds disclosure denies trading to non-stakeholders. Disclosure delivery
  is off-ledger and not modelled.
- Explicit disclosure must be enabled on participants (default on).
- Stale disclosed contracts: on the Canton 3.5.12 sandbox (SDK 3.5.5), a swap on a consumed pool supplied
  via stale explicit disclosure passed submitter interpretation and was rejected at confirmation
  as `LOCAL_VERDICT_INACTIVE_CONTRACTS`; the IDE ledger rejects it as `ContractNotFound`. Both
  reject without state change. Multi-participant topologies were not tested.

## Token Standard compatibility

- Payouts and change are production `Holding`s, which implement `Splice.Api.Token.HoldingV1`.
- Pool reserves are not holdings and are not visible through the HoldingV1 interface:
  UNSUPPORTED.
- Arbitrary Token Standard holdings as inputs, transfer factories, allocations and registry
  integration: UNSUPPORTED. Inputs must be the production `Holding` template of a co-signing
  issuer. Token Standard V2 / CIP-112 are not implemented.

## Package warning

The test package defines templates and depends on `daml-script`, so `damlc` emits
`template-interface-depends-on-daml-script`. The warning is not suppressed. Moving the
prototype templates into their own package is deferred: it needs a new package, data-dependency
wiring and duplicated fixtures, which is disproportionate for a prototype that is not deployed.
Any integration design must place the templates in a script-free package.
