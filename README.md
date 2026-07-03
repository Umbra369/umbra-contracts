<p align="center">
  <img src="assets/umbra-social-banner.png" alt="Umbra" width="100%" />
</p>

<h1 align="center">Umbra — Contracts &amp; Security</h1>

<p align="center"><b>The open, on-chain execution layer for <a href="https://umbra.finance">Umbra</a> — PulseChain's best-execution DEX aggregator.</b></p>

<p align="center">
  This repository holds the <i>contracts your funds actually touch</i> and their security record. Umbra's
  routing engine — which searches the chain's liquidity and computes the optimal split — is proprietary;
  what's open here is the part that matters for <b>trust</b>: the non-custodial execution contract, fully
  verifiable against the bytecode deployed on-chain.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-9C7956" alt="MIT"></a>
  <img src="https://img.shields.io/badge/Solidity-0.8-62472C?logo=solidity&logoColor=white" alt="Solidity">
  <img src="https://img.shields.io/badge/Foundry-forge-9C7956" alt="Foundry">
  <img src="https://img.shields.io/badge/PulseChain-369-9C7956" alt="PulseChain 369">
  <img src="https://img.shields.io/badge/source-Sourcify%20verified-3f8f5f" alt="verified">
</p>

<p align="center">
  <a href="https://umbra.finance">Website</a> ·
  <a href="https://umbra.finance/swap">Swap</a> ·
  <a href="https://umbra.finance/docs">Docs</a>
</p>

---

## What is Umbra?

Umbra finds the best execution price for a swap on **PulseChain** (chain `369`) by routing across the
chain's real liquidity — and **proves the result on-chain before you sign**. It's non-custodial: your
wallet calls the router contract directly, and Umbra never holds your funds or your keys.

## Why this repo is public

The router is the highest-stakes component — it holds user funds for the duration of a swap. So it is
**open and verifiable**: anyone can read it here and confirm it matches the bytecode deployed on-chain.
The routing *engine* that decides which pools to use and how to split a trade is proprietary and not
included; nothing in this repo reveals it, and nothing here needs to — the contract simply executes a
route it is handed, under strict, auditable safety rules.

| | |
|---|---|
| **Live router** | [`0x8AebD5A94D95F71D327D0d2aBb120B20b3a02Ebf`](https://scan.umbra.finance/address/0x8AebD5A94D95F71D327D0d2aBb120B20b3a02Ebf) (`UmbraRouterV6`) |
| **Source verification** | Sourcify — exact match |
| **License** | MIT |

## The security model

- 🔒 **Non-custodial** — your wallet calls `UmbraRouterV6` directly; the contract holds **no resident funds**. Sizing binds to the input *actually pulled* (balance-delta accounting), never `balanceOf`.
- ✅ **One honest floor** — a single `minAmountOut` is enforced on the **real output delta**, so you can never receive less than you agreed to. A route that would fall short reverts.
- 🪙 **Fee-on-transfer safe, single-tax both directions** — delta accounting handles taxed / reflection tokens across every hop, and V6 pays the transfer tax **once** on both sides: `FIRST_HOP_DIRECT` funds the first pool straight from your wallet (sells), and `LAST_HOP_DIRECT` has the final pool pay your wallet directly (buys). Buying a 5% tax token costs ~5%, not ~10%.
- 💠 **No hidden slippage capture** — the contract doesn't skim positive slippage. The only fee is a transparent **surplus share**: when Umbra's split route beats the baseline, it takes **50% of that surplus, hard-capped at 0.25% of output** (a code invariant), attested per-quote by a single-use EIP-712 signature so the baseline can't be tampered with. You net more than a standard route even after the fee.
- 🧱 **Guarded externals** — Balancer / Stable / Tide vault calls are allowlisted; a factory-authenticated, single-shot callback guards each V3 / Algebra hop.

## Contracts

| File | Role |
|---|---|
| [`contracts/src/UmbraRouterV6.sol`](contracts/src/UmbraRouterV6.sol) | The live execution router — V2/V3, switch.win/Algebra, Balancer, PulseX Stable, Balancer-V3/Tide, native PLS wrap/unwrap, Permit2, FoT single-tax delivery in **both** directions (`FIRST_HOP_DIRECT` + `LAST_HOP_DIRECT`), EIP-712 surplus-fee seam. |
| [`contracts/src/Simulator.sol`](contracts/src/Simulator.sol) | Read-only swap simulator used to realize a route's true post-tax output before signing. |
| [`contracts/src/interfaces/Interfaces.sol`](contracts/src/interfaces/Interfaces.sol) | External DEX / token interfaces. |
| [`contracts/src/UmbraRouterV5.sol`](contracts/src/UmbraRouterV5.sol) | Prior live router (2026-06-27 → 2026-07-03) — still readable on-chain at [`0x007fd5…`](https://scan.umbra.finance/address/0x007fd5c8182024e55d459dbf0d539df90ba98e53). |
| `contracts/src/UmbraRouterV3.sol`, `UmbraRouter.sol` | Earlier router versions — readable on-chain, superseded. |

## Reading the contract on-chain

A few notes for anyone exercising the **Read** tab on [scan.umbra.finance](https://scan.umbra.finance/address/0x8AebD5A94D95F71D327D0d2aBb120B20b3a02Ebf) or Sourcify:

- **Array getters need an in-range index.** `v3Factories(i)` and `algebraFactories(i)` are Solidity public arrays — querying an index past the end reverts with no message (that's the EVM, not a bug). Check `v3FactoriesLength()` / `algebraFactoriesLength()` first; today they are `5` and `1`.
- **Reverts decode as custom errors.** The router uses gas-cheap custom errors (`BadSig`, `BadDirect`, `Expired`, …) rather than revert strings. A UI without this repo's ABI shows them as raw bytes — the selectors are all defined in [`UmbraRouterV6.sol`](contracts/src/UmbraRouterV6.sol).
- **`V3` in symbol names means Uniswap-V3-style pools** (concentrated liquidity: 9mm, 9inch, pDex, …), never a router version. `v3Factories`, `allowedV3Router`, `BadV3Pool` all refer to the pool type.
- **The EIP-712 domain version is `"3"`** and stays `"3"` across router releases on purpose: the quote-signing scheme is unchanged since it was introduced, and keeping the domain stable means a router release can never silently invalidate the signing infrastructure. The domain still binds each deployment exactly, because `verifyingContract` is the router's own address.
- The `@dev` header notes inside the source narrate what each release added (v5 → v6) — release notes preserved in-file, since the deployed source is immutable once verified.

## Security

The router is **non-upgradeable** — each version is a fresh, separately-deployed contract, source-verified
on-chain (see the address above). Found a vulnerability? Please report it privately — see
[SECURITY.md](SECURITY.md).

## Build &amp; verify

```bash
forge install foundry-rs/forge-std   # the only test dependency
forge build
forge test                            # router tests (several fork PulseChain)
```

To confirm the deployed router matches this source, check the Sourcify verification on the
[contract page](https://scan.umbra.finance/address/0x8AebD5A94D95F71D327D0d2aBb120B20b3a02Ebf).

## License

[MIT](LICENSE) © Umbra
