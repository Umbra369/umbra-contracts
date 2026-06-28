# UmbraRouterV3 — Security Audit & Deployment Record (2026-06-22)

**Contract:** `contracts/src/UmbraRouterV3.sol`
**Deployed (dark):** `0xD574dF49fAF1f05b05f5177d65491c35aE407d3F` on PulseChain (chain 369)
**Method:** internal adversarial audit — two independent auditor passes (fee/signature; reentrancy/equivalence/admin) plus a structural diff against the live v2 router. Not a substitute for an external audit before the fee is enabled with real funds.

## Verdict

**GO for the dark deploy (feeBps = 0).** With the fee disabled, the EIP-712 attestation / nonce / fee machinery is entirely inert (`_verifyQuote` is never called, no signature/nonce/storage write), `net == outDelta`, and runtime behaviour is byte-equivalent to the already-vetted live v2 router. No High/Medium findings remain.

The fee path is **safe to enable later** subject to the operational controls below — but enabling it (feeBps > 0) is gated on an **external audit** and remains a manual, owner-only action.

## Findings & resolutions

| ID | Sev | Issue | Resolution |
|----|-----|-------|-----------|
| **H-1** | High | Signed quotes were replayable (no nonce / no consumption) → fee could be suppressed by replaying a stale high-`surplusFloor` quote within the deadline window. | **Fixed.** Added `quoteNonce` to `ExecuteParams`; the EIP-712 `QuoteAttestation` now binds `nonce`; `_verifyQuote` records each digest in `usedQuote` and reverts `BadSig` on reuse → every signed quote is **single-use**. Verified: replay reverts; distinct nonces both succeed (no false-positive). |
| **H-2** | High | `feeCapBps` was settable up to 100% → contradicted the "never more than 0.25%" guarantee. | **Fixed.** `MAX_FEE_CAP_BPS = 25` constant; `setFeeConfig` reverts `feeCapBps > 25`. The 0.25%-of-output ceiling is now a **code invariant**, enforced for any owner-reachable config. |
| L-1 | Low | Attestation does not bind `recipient`/`paths`. | Accepted. Not a fund-theft vector (the trade is controlled by `msg.sender`); the H-1 single-use fix removes the transfer/replay exploitability that made it relevant. |
| INFO-1 | Info | `_splitSig` doesn't reject high-`s` (ECDSA malleability). | Benign — anti-replay keys on the digest; a malleated twin recovers to a different address ≠ `signer` and reverts. No action needed. |
| INFO-2 | Info | `FeeTaken` logs `tokenOut = 0x0` on native-out. | Cosmetic; indexers treat `0x0` as PLS. |

## Properties confirmed (post-fix)

- **Ship-dark equivalence:** `feeBps == 0` ⇒ fee block skipped, `_verifyQuote` never called, `net == outDelta`, delivery + event identical to v2.
- **Reentrancy:** `execute`/`sweep` `nonReentrant`; V3 callback single-shot + factory-vouched-pool guard; `fallback` fails closed.
- **Fee math:** `fee ≤ cap ≤ outDelta` ⇒ `net` cannot underflow; floor checked on the **net** the user receives; no reachable overflow.
- **Native-out:** `net + fee == outDelta` exactly; no PLS stranded; `receive()` only from WPLS.
- **Funds-at-rest:** all sizing off `pulledIn`/balance-deltas; force-sent balances inert; only owner `sweep` can move them.
- **Admin:** two-step ownership; `setFeeConfig` range-validated + requires non-zero recipient/signer when enabled.

`forge test`: all UmbraRouterV3 suites pass (config + fee + 3 new fix-proving tests). The single unrelated failure is `RouteBacktest` (stale v2 fixture; needs Rust fixture regen).

## Deployment record

- Address: `0xD574dF49fAF1f05b05f5177d65491c35aE407d3F`
- Config (on-chain verified): `feeBps=0`, `feeCapBps=25`, `MAX_FEE_CAP_BPS=25`, `owner = feeRecipient = signer = 0xB529614bde866CAe3907915dA4c13CC3eAD61758`, `paused=false`, 5 V3 factories, WPLS set.
- Code size: 10,715 bytes. Deploy cost ≈ 1,921 PLS.

## Operational controls required BEFORE enabling the fee (feeBps > 0)

1. **External audit** of the fee path.
2. The off-chain signer **must mint a unique `quoteNonce` per quote** (the anti-replay guarantee depends on it; a buggy signer reusing nonces would self-DoS legitimate repeat trades, not lose funds).
3. Set `feeCapBps` strictly below the frontend slippage tolerance so the fee always fits inside the user's buffer.
4. Move `owner` to a timelock/multisig (it currently holds funds via `feeRecipient` and controls `setFeeConfig`).
5. Switch the `signer` from the deployer placeholder to the dedicated backend signing key.

## Not yet done (deferred, by design)

- **Wiring the live app to v3** (execbuild → v3 `ExecuteParams`, `UMBRA_ROUTER` → `0xD574…`) — deferred so it can be done with a real-swap verification. The live app remains on the audited v2 router (`0x706da75Ef6309142Df424aecB7c6CD707Ba1fEb7`).
- **Enabling the fee** — gated on the external audit + the controls above.
