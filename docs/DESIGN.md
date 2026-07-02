# ConfidencePool — Design Decisions, Trust Assumptions & Known Behavior

This document is the authoritative reference for *why* `ConfidencePool` behaves the way it
does. It exists so that any auditor — human or automated — can determine whether a given
behavior is an intentional design decision (and therefore not a bug) without outside context.

If you are evaluating a potential finding, check it against the relevant section below before
reporting. Several behaviors here are deliberate and have been considered and accepted; they are
common sources of false positives.

For the lifecycle overview, resolution paths, and parameters, see [`../README.md`](../README.md).

---

## 1. Registry-state vocabulary (read this first)

The BattleChain attack registry's active-risk states — `UNDER_ATTACK` and `PROMOTION_REQUESTED`
— do **NOT** mean "a breach is in progress." They mean the in-scope contracts are *legally
attackable by whitehats*: the agreement is live and exposed, which is its normal operating mode.
They are **not** evidence that funds were lost. Only the terminal `CORRUPTED` state is evidence
of an actual breach.

Both active-risk states can still transition to `CORRUPTED` (e.g. `markCorrupted` is reachable
from both `UNDER_ATTACK` and `PROMOTION_REQUESTED`); neither implies survival.

This distinction is the premise behind several design decisions below. Misreading the enum name
`UNDER_ATTACK` as "breach happening now" is the single most common source of false-positive
findings against this contract.

---

## 2. Resolving EXPIRED while the agreement is still attackable is correct

A pool reaching `expiry` while the registry is still in an active-risk state means the agreement
*survived the full term the stakers underwrote*. Resolving `EXPIRED` and returning principal +
bonus is the intended payout — **not an "escape."** There is no breach to settle.

`claimExpired` therefore does **NOT** defer or block on active-risk states. Its `else` branch
intentionally catches every non-terminal state (including `UNDER_ATTACK` / `PROMOTION_REQUESTED`)
and resolves `EXPIRED`. Adding an "active-risk deferral" here would trap honest stakers' funds
whenever a pool expires during normal attackable operation.

Only the terminal `CORRUPTED` state is treated specially (see §6), because only it represents an
actual breach.

**Rejected alternative:** deferring/blocking EXPIRED while the registry is in an active-risk
state. This inverts the design — it would trap principal that stakers are owed.

---

## 3. Deposits during `UNDER_ATTACK` are intentionally allowed

`_assertDepositsAllowed` blocks `PROMOTION_REQUESTED`, `PRODUCTION`, and `CORRUPTED`, but **not**
`UNDER_ATTACK`. This asymmetry is about deposit *timing*, not relative safety (both active-risk
states are attackable and can still go `CORRUPTED`):

- **`UNDER_ATTACK`:** a depositor takes on real, visible, voluntary risk. Their bonus share is
  crushed to ~zero by the k=2 weighting — entry is floored at `riskWindowStart ≈ now`, so
  `(T − entry)² ≈ 0` — and the deposit self-locks into the resolution path (`withdraw` is
  disabled once `riskWindowStart != 0`). There is no late-join *advantage* to gate against and
  no trap: it is voluntary, near-zero-reward risk capital. A staker who does not want this can
  read the live registry state before staking.
- **`PROMOTION_REQUESTED`:** the agreement has requested to exit toward `PRODUCTION`, so the risk
  window is about to close (`riskWindowEnd` imminent). Blocking deposits here stops a late join
  in the final stretch — entering with almost no remaining risk-bearing time before resolution.
  The state is still attackable; it is the *closing window*, not assured survival, that justifies
  the block.

**Why this is not a "trap" finding:** the withdraw-lock from `UNDER_ATTACK` onward is the *same*
intended commitment every staker accepts once risk materializes, and the late entrant earns
negligible bonus. Principal remains recoverable through resolution.

---

## 4. The re-flag correction window closes on the first claim (by design)

`flagOutcome` may be re-flagged pre-claim so the moderator can fix a typo'd outcome/attacker
*before any participant locks in the wrong distribution*. The window closing on the **first
claim** (not on a grace timer) is deliberate, **not a front-runnable race**:

- A claim is the distribution-locking event. Once value has left the contract, a corrective
  re-flag cannot be honored without breaking balance accounting.
- `claimsStarted` is a value-movement finality latch, **not** a moderator-only privilege. A
  staker claiming first is exercising a correct outcome, not usurping one.
- The moderator controls their correction window by flagging only on a confirmed terminal
  registry state (which is visible on-chain before they flag).

**Why this is not an access-control / front-running finding:** no privileged action is captured.
Finality is correctly tied to value movement.

---

## 5. Principal resolution is decoupled from local risk observation

If `riskWindowStart` never opens (no pool interaction observed the registry in an active-risk
state before it reached a terminal one), the "no observable risk" rule applies to the **bonus
only**: `_bonusShare` pays zero, so the bonus pool sweeps to `recoveryAddress`.

It does **NOT** gate CORRUPTED principal resolution. A terminal `CORRUPTED` registry proves
upstream risk regardless of whether the pool locally observed it, so the moderator may still
`flagOutcome(CORRUPTED, ...)` on their off-chain in-scope judgement (sweeping the pool whole).

This was changed deliberately (issue #57 / PR #63): gating principal resolution on a *local*
observation incorrectly let in-scope breached stakers escape via EXPIRED. The permissionless
`claimExpired` auto-CORRUPTED backstop lacks the moderator's judgement, so it stays conservative
and falls through to EXPIRED.

**Rejected alternative:** re-adding a `riskWindowStart != 0` guard to `flagOutcome`'s CORRUPTED
branch. This re-introduces the exact bug PR #63 fixed.

### The no-risk-window CORRUPTED race (intended; moderator must flag promptly)

"The moderator may still flag CORRUPTED" holds only **until the first `claimExpired` call**. With
`riskWindowStart == 0` on a terminal-`CORRUPTED` registry, `claimExpired` falls through to EXPIRED
and latches `claimsStarted`, after which `flagOutcome(CORRUPTED, ...)` reverts `OutcomeAlreadySet`.
So a staker can permissionlessly resolve EXPIRED (refunding themselves) and foreclose the correct
CORRUPTED outcome, in the window where the breach is in-scope but the moderator hasn't flagged yet.

This is **accepted, not a bug**: auto-finalizing CORRUPTED here (the finding's recommendation) is
exactly the scope-blind over-punishment §6 rejects — it could sweep principal on an *out-of-scope*
breach where SURVIVED was correct. The conservative EXPIRED is the staker-favorable default the
backstop must take without an observed risk window, and finality-on-resolution is uniform by design
(§4). The moderator is the canonical CORRUPTED decision-maker and is expected to flag a known
in-scope breach promptly — they have the whole pool term plus the post-expiry window first. The
`riskWindowStart != 0` grace backstop only protects against a *permanently-absent* moderator, and
by definition cannot apply when no risk window was observed. (Deferring `claimExpired` here during
the grace window was considered and rejected for the same scope-blind / uniform-finality reasons.)

---

## 6. Auto-CORRUPTED backstop is scope-blind and staker-pessimistic (accepted trust assumption)

The permissionless auto-CORRUPTED path in `claimExpired` fires only when the registry reads
`CORRUPTED` **and** `riskWindowStart != 0`, and only after `expiry + MODERATOR_CORRUPTED_GRACE`
(180 days). It is a backstop against a permanently-unavailable moderator; under the DAO-moderator
trust model it should never fire in practice.

It is **scope-blind**: the registry exposes only agreement-level state, so the backstop cannot
tell in-scope corruption (CORRUPTED is correct) from out-of-scope corruption (SURVIVED is correct
— only the moderator can flag that). It assumes the worst for stakers: a CORRUPTED agreement
always auto-resolves CORRUPTED.

**Accepted consequence:** if the moderator is absent for the full grace window AND the breach was
out-of-scope, stakers lose principal + bonus to `recoveryAddress` despite their in-scope
contracts surviving. The inverse default (principal-returning EXPIRED) is **not** strictly safer
— it would let genuine in-scope corruption escape punishment. Only a live moderator, or registry
data richer than agreement-level state, resolves this correctly.

### On `riskWindowStart` as the gate, and `pokeRiskWindow`

The gate keys on `riskWindowStart != 0`. That flag is sealable by anyone via permissionless
`pokeRiskWindow()` (or any ordinary pool interaction) during the active-risk interval the registry
passes through. This is the intended, outcome-neutral observation mechanism — **not** an attacker
lever:

- Sealing the window is the *normal* path; its absence only reflects that nobody interacted with
  the pool for the entire interval.
- The out-of-scope + absent-moderator loss above is the accepted consequence **regardless of who**
  seals the window. A poke does not "manufacture" it.
- Gating on the moderator alone instead would re-trap funds when the DAO is permanently
  unavailable — the exact failure this backstop exists to prevent.

---

## 7. Bonus distribution: k=2 time-weighting, `T` anchoring, and the degenerate fallback

The bonus pool is split with a k=2 time-weighted formula: each deposit contributes
`amount × (T − entryTime)²` to its score, summed per-deposit (top-ups are not blended into a
single weighted-average entry time — that would lose the Jensen gap and let users farm share by
splitting across addresses). Squaring crushes late entrants. Per-user and global sums maintain
the score in O(1) per claim via `T²·Σa − 2T·Σ(a·t) + Σ(a·t²)`.

`T` is `riskWindowEnd` for SURVIVED resolutions or `expiry` for EXPIRED. Effective entry time is
floored at `riskWindowStart`: pre-risk capital earns no time weight. So "squaring crushes late
entrants" applies only *within* the observed risk window — every deposit made before the seal
(including the one that triggers it) floors to `riskWindowStart` and is amount-weighted among that
cohort. Intentional: pre-risk calendar time is not at-risk time, so equal per-token weight there is
correct, not a leak.

### `T` is the first-observed terminal moment (accepted timing residual)

`T` is pinned to the *first observed* terminal moment, not the resolving call's block timestamp.
This closes the grief vector where a caller could shift distribution by varying when resolution is
triggered.

**Accepted residual:** the window bounds seal at the *observation* block, not the true transition
block, because the registry exposes no canonical per-agreement transition timestamp (state is
derived from boolean flags) — first-observation is the best anchor available. Biasing `T` by
withholding observation is a *contested public race*: any counterparty with the opposite incentive
can `pokeRiskWindow()` the instant the registry transitions, collapsing the bias to ~zero, and it
only ever redistributes the bonus pool among stakers (no principal effect, no third-party loss).

**Rejected alternative:** anchoring `T` to `expiry` unconditionally. It removes the lever but
discards the k=2 time-weighting entirely.

### The `globalScore == 0` amount-weighted fallback

When `globalScore == 0` (e.g. flag in the same block as the only stake, or a risk window first
observed at/after `expiry` so every `(T − entry)` collapses to zero), `_bonusShare` falls back to
an amount-weighted split.

This is **distinct** from the `riskWindowStart == 0` "no observable risk" rule (§5), which pays
zero and sweeps bonus to recovery. Here a window *was* observed, so stakers are owed the bonus, but
there is no measured time spread to weight by — splitting it amount-weighted among them is the
intended neutral fallback. The two cases route bonus to different destinations on purpose.

---

## 8. Scope is a fixed, pool-local commitment

The pool maintains its own scope (a flat `address[]` of BattleChain accounts), a subset of the
agreement's BattleChain scope at scope-set time, validated via `IAgreement.isContractInScope`.
The pool commits to BattleChain-only insurance: the attack registry is BattleChain-native and the
agreement's multichain metadata isn't validatable on-chain.

The sponsor can update scope freely while the registry is in `NOT_DEPLOYED` / `NEW_DEPLOYMENT`
(pre-attack staging). Scope locks permanently on the first interaction observing any other state.
Once locked, the pool's coverage is fixed even if the sponsor later expands the agreement — so
post-stake additions to the underlying agreement do **not** extend this pool's coverage, and
stakers' exposure is bounded by what they signed up for at deposit time.

The pool stores scope as a public commitment but does **NOT** gate `flagOutcome` against scope:
the moderator's off-chain judgement is the source of truth on what triggered corruption, and the
published scope is the binding audit trail. A pool's outcome therefore decouples from the
registry's: if the agreement is `CORRUPTED` but the vulnerability fell outside this pool's scope,
the moderator flags `SURVIVED` and stakers recover stake + bonus. `CORRUPTED` is reserved for when
the in-scope contracts were the breach surface.

**Residual trade-off:** if the sponsor *narrows* the agreement, the pool's locked scope may
reference accounts no longer in the agreement — but the pool's own commitment to stakers remains
the binding source of truth.

---

## 9. Withdraw lifecycle

`withdraw()` exits the caller's full eligible stake in one call. It is gated by registry state:
allowed in `NOT_DEPLOYED`, `NEW_DEPLOYMENT`, and `ATTACK_REQUESTED`; permanently disabled from
`UNDER_ATTACK` onward (gated additionally on the one-way `riskWindowStart != 0` latch, so an
upstream registry rewind cannot re-open it).

This closes the race in which a staker observes an attack on-chain and front-runs `flagOutcome`
with `withdraw()` to escape with full value. Withdrawing before a flag forfeits any bonus the
caller would have earned (the claim paths require nonzero `eligibleStake`).

The withdraw escape hatch (open for the entire pre-attack window) is also why "no observed risk →
no bonus" is fair: a staker only forfeits the exit option once risk has actually materialized,
which is exactly when they begin earning the risk premium. A sponsor cannot grief stakers by
keeping the agreement out of attackable mode — stakers can freely exit until risk materializes.

---

## 10. Sponsor trust surface

- **`recoveryAddress`** — CORRUPTED sweep destination. Receives the full pool (including stakers'
  principal) under bad-faith CORRUPTED; only excess/dust under SURVIVED/EXPIRED/good-faith.
- **`expiry`** — sponsor-mutable only **until the first stake** (one-way `expiryLocked` latch).
  This protects staker reliance: once anyone has deposited against a given deadline (which feeds
  the k=2 weighting as `T` for the EXPIRED path), the sponsor cannot move it. The latch
  intentionally does **not** reset when stake is withdrawn — resetting it would let the sponsor
  move `expiry` during an all-stakers-exited moment and harm the next cohort.
- **Pool scope** — see §8.

All staker-relevant state is on-chain; stakers should verify pool parameters before depositing.
The `recoveryAddress` value is informational only on the BattleChain agreement side (the
agreement's `Chain.assetRecoveryAddress` is a CAIP-2 string), so the pool stores its own typed
`address recoveryAddress` for token transfers.

---

## 11. External dependency: the registry is a trusted singleton (out of adversarial model)

Resolution reads agreement state live via `_getAgreementState`; `safeHarborRegistry` is pinned at
init, the attack-registry pointer is never cached, and there is no per-clone repoint path.

The `SafeHarborRegistry` and its attack-registry pointer are a **trusted, protocol-DAO-controlled
singleton** — an explicit trust assumption. `setAttackRegistry` is `onlyOwner` (the DAO, the same
entity trusted as moderator) and reverts on `address(0)`, so a zeroed pointer is unreachable. A
registry that is bricked or repointed to one reporting false state is the trusted entity attacking
its own infrastructure — **out of the adversarial model**, equivalent to a malicious moderator
(who compromises resolution far more directly anyway). No funds can be stolen; the worst case is a
recoverable liveness delay or principal *returned* to stakers rather than swept.

**Rejected mitigations:** a per-clone repoint setter (contradicts the §8/§10 immutability
guarantee and hands the sponsor a resolution lever); per-clone pinning of the attack-registry
instance (would brick every existing pool on a legitimate DAO registry migration — more likely and
more severe than the risk it prevents).

A benign upstream state *rewind* cannot re-open `withdraw`: that is gated on the one-way
`riskWindowStart != 0` latch (§9), not solely on live state.

---

## 12. CORRUPTED bounty mechanics

For good-faith CORRUPTED, `bountyEntitlement` and `corruptedReserve` are both set to
`snapshotTotalStaked + snapshotTotalBonus` — i.e. the **entire pool** is the named attacker's
bounty (there is no separate "surplus" alongside an unclaimed bounty in the normal case).

- `claimAttackerBounty` pays `min(remaining, freeBalance)` — the *full* remaining entitlement, not
  a caller-chosen partial. With a normal token, one call satisfies it and unblocks `claimCorrupted`.
- The `MustClaimBountyFirst` gate (good-faith only) and the `sweepUnclaimedCorrupted` deadline are
  intentional: the pool is reserved for the named whitehat for `CORRUPTED_CLAIM_WINDOW` (180 days),
  after which anyone sweeps the remainder to `recoveryAddress`. A donation landing while the bounty
  is unclaimed is held until the attacker claims (then swept immediately) or the window elapses — a
  bounded, recoverable delay, not a lock. A true stuck-state would require a defective stake token
  that freezes the pool's own balance, which the factory allowlist exists to exclude.

## 13. Auto-resolution branch is registry-determined, not caller-chosen

In `claimExpired`'s auto-resolution the branch is fixed by the live registry state at the first
post-expiry call, not chosen by the caller: `CORRUPTED` (+ observed risk window, after grace) →
auto-CORRUPTED; `PRODUCTION` → SURVIVED; everything else → EXPIRED. A caller cannot pick SURVIVED
over EXPIRED — if the state is not `PRODUCTION`, EXPIRED is the only valid outcome (even a
moderator `flagOutcome(SURVIVED)` requires a terminal registry state). The residual around *when*
the terminal moment is first observed is covered in §7.
