# Security Policy

The `UmbraRouterV6` contract holds user funds for the duration of a swap, so it is the highest-stakes
component of Umbra. Responsible disclosure is genuinely appreciated.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

- **GitHub Security Advisory** — [open a private advisory](https://github.com/Umbra369/umbra-contracts/security/advisories/new) (preferred).
- Or email **security@umbra.finance** with steps to reproduce and an impact assessment.

We aim to acknowledge within 48 hours and to keep you updated through triage and fix.

## Scope

In scope:

- `contracts/src/UmbraRouterV6.sol` (the live router) and the contracts it depends on
  (`Simulator.sol`, `interfaces/Interfaces.sol`, `lib/*`).
- Anything that could cause loss of user funds, a swap delivering less than its enforced
  `minAmountOut`, an unauthorized state change, or the surplus fee exceeding its 0.25% cap.

Out of scope:

- Umbra's off-chain routing engine (not part of this repository).
- Prior, superseded router deployments (`UmbraRouterV3.sol`, `UmbraRouter.sol`) — kept here for
  historical reference only.
- Issues requiring a malicious or compromised RPC, or PulseChain consensus-level assumptions.

## Safe harbor

We will not pursue or support legal action against good-faith security research that respects this
policy, avoids privacy violations and service degradation, and gives us reasonable time to remediate
before any disclosure.
