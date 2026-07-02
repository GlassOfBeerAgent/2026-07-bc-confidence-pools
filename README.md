# Protocol Name

BattleChain Confidence Pools


### Prize Pool TO BE FILLED OUT BY CYFRIN

- Total Pool - $12000
- H/M - $10000
- Low - $2000

- Starts: July 9th, 2026
- Ends: July 16th, 2026

- nSLOC: 589

[//]: # (contest-details-open)

## About the Project

Confidence Pools let sponsors bootstrap third-party confidence around an active Safe Harbor agreement on BattleChain. Stakers deposit capital, sponsors top up an optional bonus, and each pool settles based on a moderator-flagged outcome or an expiry backstop. The pool acts as an on-chain confidence mechanism: stakers economically signal their belief that the in-scope contracts will survive the agreement term without being corrupted, and are rewarded from the bonus pool if they do.

- A UUPS-upgradeable `ConfidencePoolFactory` deploys non-upgradeable `ConfidencePool` clones (one or many per agreement) and gates stake tokens behind an owner-controlled allowlist.
- Each clone holds all stake and bonus funds and commits to its own scope (a flat list of BattleChain accounts), locked permanently once the registry leaves pre-attack staging.
- Registry state is read live from `IBattleChainSafeHarborRegistry.getAttackRegistry()` and never cached.
- Resolution paths: SURVIVED (stake + k=2 time-weighted bonus share), EXPIRED (same payout via the expiry backstop), and CORRUPTED (good-faith attacker bounty, or bad-faith full-pool sweep to the recovery address).
- The bonus is split with a k=2 time-weighted formula that crushes late entrants within the observed risk window.

> **Auditors:** design decisions, trust assumptions, and known/intentional behavior (and why several common findings are false positives) are documented in `docs/DESIGN.md`. Check a suspected finding against it before reporting.

[Documentation](docs/DESIGN.md)
[BattleChain Safe Harbor Contracts](https://github.com/Cyfrin/battlechain-safe-harbor-contracts)
[BattleChain Docs](https://docs.battlechain.com)

## Actors

There are 5 main actors in this protocol:

**1. Factory Owner**

RESPONSIBILITIES:

- deploys the factory and pool implementation,
- manages the Safe Harbor registry and default moderator addresses,
- controls the stake-token allowlist,
- can pause / unpause the factory,
- authorizes UUPS upgrades.

LIMITATIONS:

- two-step ownership transfer (`Ownable2Step`),
- cannot move funds held by pool clones.

**2. Pool Sponsor (Pool Owner)**

RESPONSIBILITIES:

- creates a pool via the factory with an initial scope and an allowlisted stake token,
- controls `recoveryAddress` (CORRUPTED sweep destination),
- controls `expiry` (only until the first stake),
- controls pool scope (only until the registry leaves pre-attack staging),
- can pause / unpause the pool's stake/bonus paths.

LIMITATIONS:

- cannot alter scope once locked,
- cannot alter `expiry` after the first stake,
- pause does not affect resolution/withdrawal paths.

**3. Moderator (Protocol DAO)**

RESPONSIBILITIES:

- flags the pool outcome (SURVIVED / CORRUPTED / EXPIRED) via `flagOutcome`,
- may re-flag a correction before the first claim,
- names the whitehat attacker for good-faith CORRUPTED.

LIMITATIONS:

- set by the factory at clone time and immutable per-pool,
- correction window closes on first claim (finality is value-movement),
- 180-day grace fallback exists as defense against moderator unavailability.

**4. Staker**

RESPONSIBILITIES:

- deposits stake via `stake` (counts toward the bonus formula immediately),
- can fully exit via `withdraw` while the registry is in any pre-attack state,
- claims stake + k=2 time-weighted bonus share via `claimSurvived` / `claimExpired`.

LIMITATIONS:

- withdrawals permanently disabled from `UNDER_ATTACK` onward,
- withdrawing forfeits any bonus claim,
- no owner- or moderator-defined rights.

**5. Bonus Contributor / Attacker**

RESPONSIBILITIES:

- Bonus Contributor: can contribute to the bonus pool permissionlessly via `contributeBonus` (no claim rights),
- Attacker (good-faith CORRUPTED only): named by the moderator, has 180 days to claim the bounty via `claimAttackerBounty`.

LIMITATIONS:

- bonus contributors gain no claim on stake or bonus,
- attacker bounty capped at the snapshot of total staked + total bonus.

[//]: # (contest-details-close)

[//]: # (scope-open)

## Scope (contracts)

```
src/
├── ConfidencePool.sol
├── ConfidencePoolFactory.sol
```

BattleChain Safe Harbor interfaces (`IAgreement`, `IAttackRegistry`, `IBattleChainSafeHarborRegistry`) are pulled in as a git submodule at `lib/battlechain-safe-harbor-contracts` and are out of scope (dependency).

## Compatibilities

```
Compatibilities:

  Blockchains:
      - BattleChain (EVM-compatible L2)
  Solidity:
      - 0.8.26 (via-IR, optimizer 200 runs)
  Tokens:
      - ERC20 (standard only; fee-on-transfer and rebasing tokens are NOT supported)
```

[//]: # (scope-close)


[//]: # (getting-started-open)

## Setup

Build:

```
git clone https://github.com/CodeHawks-Contests/2026-07-bc-confidence-pools.git

forge install

forge build
```

Tests:

```
forge test

# fork tests (requires a BattleChain RPC)
forge test --match-path 'test/fork/*' --rpc-url battlechain_testnet
```

RPC endpoints:

`foundry.toml` maps the `battlechain_testnet` / `battlechain_mainnet` aliases to the
`BATTLECHAIN_TESTNET_RPC` / `BATTLECHAIN_MAINNET_RPC` env vars (see `.env.example`).
The fork tests under `test/fork/` resolve `battlechain_testnet` to `BATTLECHAIN_TESTNET_RPC`.

```
BATTLECHAIN_TESTNET_RPC=https://testnet.battlechain.com
BATTLECHAIN_MAINNET_RPC=https://mainnet.battlechain.com
```

[//]: # (getting-started-close)

[//]: # (known-issues-open)

## Known Issues

Known/intentional behaviors and trust assumptions are documented in `docs/DESIGN.md`, which also explains why several common findings are false positives. Check a suspected finding against it before reporting.

[//]: # (known-issues-close)
