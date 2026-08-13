# canton-treasury-amm

`canton-treasury-amm` is a Daml/Canton constant-product automated market maker for swapping a tokenized U.S. Treasury asset against a USD stablecoin. It provides single-use pool initialization, exact-input swaps in both directions, liquidity positions, proportional withdrawal, slippage and deadline protection, deterministic rounding, and atomic settlement.

## Model

Pricing follows Uniswap V2's `x * y = k` design. A 30 bps fee is applied with the `997 / 1000` multiplier and remains in the reserves for LPs. Swap payouts and liquidity withdrawals round down, liquidity contributions round up, and all residual dust stays in the pool.

The per-asset fee counters are reporting-only and saturate at the reserve cap, so a long-lived pool cannot overflow them and lose a swap direction. Saturation never affects pricing, reserves, invariant enforcement, or settlement. Exact lifetime fee analytics must be derived from the transaction stream rather than from these counters.

Proportional share, contribution, and withdrawal results are range-checked before they are narrowed to an integer atom count, so an out-of-range computation is rejected with `amm/arithmetic-range` instead of an arithmetic exception.

Amounts use `Decimal` at contract boundaries with 10^-10-unit atoms. Wide calculations use `Numeric 0`. Each reserve is capped at 10^17 atoms, or 10,000,000.0 asset units, so every adjusted-invariant intermediate remains within the available arithmetic range.

Initial LP supply is `floor(sqrt(treasuryAtoms * stableAtoms))`. One share atom is permanently locked. This intentionally differs from Uniswap V2's 1,000 locked units, so initialization also requires at least 10^6 gross share atoms to reject dust-sized pools and reduce first-depositor inflation risk.

The contract model consists of issuer-controlled `TokenInstrument` and `Holding` contracts, a provider-controlled single-use `PoolSetup`, an immutable operator-and-governance-signed `Pool`, matching `LiquidityPosition` contracts whose signatories derive from the pool identifier, and `SwapIntent` contracts created through a `SwapIntentFactory`. Contract keys are not used; every pool operation consumes the current pool contract and creates exactly one versioned successor.

Holdings of the same instrument are only mergeable when they disclose to the same set of auditors. Auditor sets are compared by membership, so list order and duplicate entries do not matter.

## Authorization and privacy

The pool operator and governance are co-signatories, so neither can create pool state alone. Holding owners control exact transfers. Direct pool operations add the trader or provider as a controller, while `SwapIntent` execution requires both the operator and governance and carries the trader's authority from the intent.

`SwapIntent` is signed by the trader, the operator, and governance. Because a trader cannot supply operator and governance authority, intents are created only through `SwapIntentFactory`, whose trader-controlled choice contributes the factory's operator and governance signatures. The factory holds the authorized trader list and validates the trader, both amounts against the atom cap, and the deadline before creating an intent, so invalid requests return `amm/unauthorized-trader`, `amm/invalid-amount`, `amm/reserve-cap`, or `amm/deadline` rather than a template precondition failure. Cancellation remains trader-only and execution remains jointly controlled by the operator and governance.

Traders are not permanent pool observers. Read visibility is supplied per transaction with explicit contract disclosures:

| Flow | Submitter | Explicit disclosures |
| --- | --- | --- |
| Pool initialization | Initial provider | None |
| Direct swap | Trader | Pool and both reserve holdings |
| Add or remove liquidity | Provider | Pool and both reserve holdings |
| `SwapIntent` execution | Operator and governance | Trader input holding |

## Trust model

The operator owns the reserve `Holding` contracts. Holding transfers are controlled by the owner, so the operator can transfer or archive a reserve outside any `Pool` choice. Governance is required to create `Pool` state but does not prevent that unilateral movement. Moving or archiving a referenced reserve bricks the affected pool state, and the resulting failure may surface as an engine-level inactive-contract error rather than a domain rejection.

This MVP therefore trusts the operator as reserve custodian. It also trusts the operator and governance not to collude: jointly they can create arbitrary `Pool` and `LiquidityPosition` state, including share supplies that dilute existing providers. The model deliberately contains no recovery mechanism for either case.

## Build and test

The installed Daml tools are managed by `dpm`, which must be added to `PATH` in each shell:

```sh
export PATH="$HOME/.dpm/bin:$PATH"
dpm build --all
```

Lint both packages and run the Daml Script suite:

```sh
export PATH="$HOME/.dpm/bin:$PATH"
(cd daml/canton-treasury-amm && dpm damlc lint)
(cd daml/canton-treasury-amm-tests && dpm damlc lint)
(cd daml/canton-treasury-amm-tests && dpm test)
```

To verify the generated test DAR against Canton, start the sandbox in one shell:

```sh
export PATH="$HOME/.dpm/bin:$PATH"
dpm sandbox
```

Then run every script from another shell:

```sh
export PATH="$HOME/.dpm/bin:$PATH"
dpm script --dar daml/canton-treasury-amm-tests/.daml/dist/canton-treasury-amm-tests-0.1.0.dar --all --ledger-host localhost --ledger-port 6865 --upload-dar true -w
```

Restart the sandbox before uploading a changed DAR with the same package name and version. Canton uses wall-clock time; if static-time control is unavailable, only the expired-deadline script may be excluded with `--skip-script-name CantonTreasuryAmm.Test.SwapIntent:expiredDeadlinesRejectDirectSwapAndIntent`.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
