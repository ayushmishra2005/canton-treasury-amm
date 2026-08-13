# canton-treasury-amm

`canton-treasury-amm` is a Daml/Canton constant-product automated market maker for swapping a tokenized U.S. Treasury asset against a USD stablecoin. It provides single-use pool initialization, exact-input swaps in both directions, liquidity positions, proportional withdrawal, slippage and deadline protection, deterministic rounding, and atomic settlement.

## Model

Pricing follows Uniswap V2's `x * y = k` design. A 30 bps fee is applied with the `997 / 1000` multiplier and remains in the reserves for LPs; fee counters are reporting-only. Swap payouts and liquidity withdrawals round down, liquidity contributions round up, and all residual dust stays in the pool.

Amounts use `Decimal` at contract boundaries with 10^-10-unit atoms. Wide calculations use `Numeric 0`. Each reserve is capped at 10^17 atoms, or 10,000,000.0 asset units, so every adjusted-invariant intermediate remains within the available arithmetic range.

Initial LP supply is `floor(sqrt(treasuryAtoms * stableAtoms))`. One share atom is permanently locked. This intentionally differs from Uniswap V2's 1,000 locked units, so initialization also requires at least 10^6 gross share atoms to reject dust-sized pools and reduce first-depositor inflation risk.

The contract model consists of issuer-controlled `TokenInstrument` and `Holding` contracts, a provider-controlled single-use `PoolSetup`, an immutable operator-and-governance-signed `Pool`, matching `LiquidityPosition` contracts, and trader-signed `SwapIntent` contracts jointly executed by the operator and governance. Contract keys are not used; every pool operation consumes the current pool contract and creates exactly one versioned successor.

## Authorization and privacy

The pool operator and governance are co-signatories, so neither can create pool state alone. Holding owners control exact transfers. Direct pool operations add the trader or provider as a controller, while `SwapIntent` execution requires both the operator and governance and carries the trader's authority from the intent.

Traders are not permanent pool observers. Read visibility is supplied per transaction with explicit contract disclosures:

| Flow | Submitter | Explicit disclosures |
| --- | --- | --- |
| Pool initialization | Initial provider | None |
| Direct swap | Trader | Pool and both reserve holdings |
| Add or remove liquidity | Provider | Pool and both reserve holdings |
| `SwapIntent` execution | Operator and governance | Trader input holding |

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

Restart the sandbox before uploading a changed DAR with the same package name and version. Canton uses wall-clock time; if static-time control is unavailable, only the expired-deadline script may be excluded with `--skip-script-name CantonTreasuryAmm.Test.SwapIntent:expiredIntentRejectsWithoutChangingState`.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
