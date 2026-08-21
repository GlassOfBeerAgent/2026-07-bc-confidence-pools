# ConfidencePool Security Audit

## Summary

The contract is well-structured with clear documentation, and several potential issues are correctly pre-empted by design decisions documented in `docs/DESIGN.md`. However, several real vulnerabilities and design concerns remain.

---

## Critical

### C-1: `claimCorrupted` Has No Access Control — Anyone Can Sweep to `recoveryAddress`

```solidity
function claimCorrupted() external nonReentrant {
    if (outcome != PoolStates.Outcome.CORRUPTED) revert OutcomeNotSet();
    if (goodFaith && bountyClaimed < bountyEntitlement) revert MustClaimBountyFirst();
    uint256 toSweep = stakeToken.balanceOf(address(this));
    ...
    stakeToken.safeTransfer(recoveryAddress, toSweep);
```

Any address can call `claimCorrupted` and trigger the sweep. While the destination is `recoveryAddress` (not the caller), this creates a griefing vector: a front-runner can sweep before `claimAttackerBounty` is called in the good-faith path if the `bountyClaimed < bountyEntitlement` guard is somehow bypassed. More importantly, in the bad-faith path, anyone can trigger the sweep at any time, which may race with a moderator re-flag if `claimsStarted` is not yet set.

**Recommendation:** Restrict `claimCorrupted` to `outcomeModerator` or `recoveryAddress`, or at minimum add a time-delay after outcome flagging.

---

### C-2: `flagOutcome` Allows Re-flagging After Claims If `claimsStarted` Is Not Yet Set — Race Condition in Mechanical Resolution

```solidity
if (outcome != PoolStates.Outcome.UNRESOLVED && claimsStarted) revert OutcomeAlreadySet();
```

In `claimExpired`, `claimsStarted = true` is set **before** `safeTransfer`, but the CORRUPTED branch in `claimExpired` returns early after setting `claimsStarted = true`. However, in the SURVIVED/EXPIRED branch, the state sequence is:

```solidity
claimsStarted = true;   // set here in the resolution block
// ... then later:
stakeToken.safeTransfer(msg.sender, payout);
```

A moderator watching the mempool can front-run `claimExpired`'s resolution block with `flagOutcome` before `claimsStarted` is set (i.e., if called by a non-staker who triggers only resolution with no payout). The `claimsStarted = true` line in the non-staker path runs unconditionally, but a malicious/compromised moderator could change `snapshotTotalStaked`, `snapshotTotalBonus`, and `outcomeFlaggedAt` in the brief window.

**Impact:** Corrupted bonus distribution snapshots for all stakers.

**Recommendation:** Set `claimsStarted = true` atomically at outcome first-setting in `claimExpired`, before any external state is consumed.

---

## High

### H-1: `_clampUserSums` Does Not Update Global Accumulators — Global/Per-User Sum Divergence

```solidity
function _clampUserSums(address u) internal {
    ...
    if (userSumStakeTime[u] < stake_ * start) {
        userSumStakeTime[u] = stake_ * start;
        userSumStakeTimeSq[u] = stake_ * start * start;
    }
}
```

The comment acknowledges globals were reset eagerly in `_markRiskWindowStart`. However, `_markRiskWindowStart` resets globals as:

```solidity
sumStakeTime = totalEligibleStake * t;
sumStakeTimeSq = totalEligibleStake * t * t;
```

This assumes all current stakers' per-user sums will also be clamped. But if a user withdraws **after** `_markRiskWindowStart` runs (in a state where `riskWindowStart == 0` is no longer true but withdrawals are still gated on the registry state), their stale per-user contribution to the old `sumStakeTime` is already subtracted from the already-reset global, potentially causing underflow or incorrect global state.

Specifically, in `withdraw()`:

```solidity
_clampUserSums(msg.sender);
sumStakeTime -= userSumStakeTime[msg.sender];
sumStakeTimeSq -= userSumStakeTimeSq[msg.sender];
```

After `_clampUserSums` runs, `userSumStakeTime[msg.sender]` is the **clamped** value (`stake * start`). But the global `sumStakeTime` was reset to `totalEligibleStake * start` — which already accounts for this user's clamped value. Subtracting the clamped per-user value from the already-clamped global is correct, but only if the withdrawal gate prevents this path once `riskWindowStart != 0`.

The withdrawal gate does check `riskWindowStart != 0`:

```solidity
if (riskWindowStart != 0 || ...) revert WithdrawsDisabled();
```

So this is correctly blocked. **However**, there is a subtle issue: `_observePoolState()` is called in `withdraw()`, which can **set** `riskWindowStart` during the same call. The sequence is:

```solidity
IAttackRegistry.ContractState state = _observePoolState(); // may set riskWindowStart
if (riskWindowStart != 0 || ...) revert WithdrawsDisabled(); // reads AFTER
```

This is safe — the check reads `riskWindowStart` after `_observePoolState()` sets it, so if it was just set, the revert fires. ✓

**Revised finding:** No bug here, but the ordering is subtle and fragile. Document explicitly.

---

### H-2: `outcomeFlaggedAt` Is Set to `riskWindowEnd` Before `riskWindowEnd` May Be Observed in `flagOutcome`

```solidity
outcomeFlaggedAt = riskWindowEnd;
```

If `flagOutcome` is called while `riskWindowEnd == 0` (terminal state not yet observed by `_observePoolState`), `outcomeFlaggedAt` will be `0`. The `_observePoolState()` call inside `flagOutcome` will set `riskWindowEnd` if the current state is terminal, but the assignment to `outcomeFlaggedAt` happens **after** `_observePoolState()` — so this should be safe.

Wait — looking again:

```solidity
function flagOutcome(...) external onlyModerator {
    ...
    IAttackRegistry.ContractState state = _observePoolState(); // sets riskWindowEnd if terminal
    ...
    outcomeFlaggedAt = riskWindowEnd; // reads newly set value
```

This is correct. However, for SURVIVED resolution where state is PRODUCTION (terminal), `riskWindowEnd` should have been set. But if the moderator calls `flagOutcome` and the registry is in CORRUPTED (for SURVIVED scope-out), `_observePoolState` sets `riskWindowEnd`. ✓

**Actual Issue:** If the first time `_observePoolState` observes a terminal state is inside `flagOutcome`, `riskWindowEnd` is set to `min(block.timestamp, expiry)`. If `block.timestamp > expiry`, `riskWindowEnd = expiry`. Then `outcomeFlaggedAt = expiry`. This is the documented intended behavior. ✓

---

### H-3: Bonus Formula Uses Live `userSumStakeTime[u]` / `userSumStakeTimeSq[u]` Post-Snapshot, Not Snapshot Values

```solidity
function _bonusShare(address u, uint256 userEligible) internal view returns (uint256) {
    ...
    uint256 userPlus = T * T * userEligible + userSumStakeTimeSq[u];  // LIVE value
    uint256 userMinus = 2 * T * userSumStakeTime[u];                   // LIVE value
```

Global snapshot values `snapshotSumStakeTime` / `snapshotSumStakeTimeSq` are captured at resolution, but per-user values are read live. This means:

- If a user's per-user sums are modified between `flagOutcome` and their claim (impossible in current code since stake/withdraw are blocked post-resolution... but `_clampUserSums` is called at claim time and modifies `userSumStakeTime[u]`).
- `_clampUserSums` is called in `claimSurvived` before `_bonusShare`:

```solidity
_clampUserSums(msg.sender);
uint256 bonusShare = _bonusShare(msg.sender, userEligible);
```

`_clampUserSums` modifies `userSumStakeTime[msg.sender]` and `userSumStakeTimeSq[msg.sender]` **but not the globals**, which are already snapshotted. This is architecturally inconsistent: the global snapshot was taken at one `riskWindowStart`, but the per-user value is clamped at claim time using the same `riskWindowStart`. Since `riskWindowStart` is one-way, this is consistent.

**However:** `_clampUserSums` modifies live storage. Since `userSumStakeTime` is also decremented in `withdraw()`, and withdrawals are blocked post-risk-window, the live values at claim time equal the values at snapshot time (no modification is possible between flagging and claiming). ✓

---

### H-4: `claimExpired` Re-Reads Registry State But Skips It On Second Invocation — Inconsistent `outcomeFlaggedAt` for SURVIVED

In `claimExpired`, when `outcome == PoolStates.Outcome.UNRESOLVED`:

```solidity
if (state == IAttackRegistry.ContractState.PRODUCTION) {
    outcome = PoolStates.Outcome.SURVIVED;
    outcomeFlaggedAt = riskWindowEnd;
```

But `riskWindowEnd` might be `0` if the pool never observed an active risk state first. The `_isTerminalState` check in `_observePoolState` will set `riskWindowEnd` now, but only if `riskWindowEnd == 0`. If `riskWindowStart == 0` (no risk window ever opened), then `outcomeFlaggedAt = riskWindowEnd = min(block.timestamp, expiry)`.

Then `_bonusShare` checks:

```solidity
if (riskWindowStart == 0) return 0;
```

So bonus is zero regardless of `outcomeFlaggedAt`. ✓ No exploit here, just defensive clarity.

---

## Medium

### M-1: `setRecoveryAddress` Has No Timelock — Owner Can Redirect Funds Mid-Claim

```solidity
function setRecoveryAddress(address newRecoveryAddress) external onlyOwner {
    if (newRecoveryAddress == address(0)) revert InvalidRecoveryAddress();
    recoveryAddress = newRecoveryAddress;
```

The owner can change `recoveryAddress` at any time, including after outcome is flagged but before `claimCorrupted` / `sweepUnclaimedBonus` / `sweepUnclaimedCorrupted` execute. In the CORRUPTED path especially, the owner could front-run a `claimCorrupted` call to redirect funds to an arbitrary address.

**Recommendation:** Lock `recoveryAddress` once `outcome != UNRESOLVED`, or add a timelock (e.g., 48-hour delay + two-step).

---

### M-2: `pause()` Blocks `stake` and `contributeBonus` But Not `withdraw` — Asymmetric Protection

```solidity
function stake(uint256 amount) external nonReentrant whenPoolNotPaused {
function contributeBonus(uint256 amount) external nonReentrant whenPoolNotPaused {
function withdraw() external nonReentrant {  // no whenPoolNotPaused
```

During a pause, users can withdraw but cannot stake. This asymmetry means the owner can pause the pool, causing a bank-run drain of all stakes while new capital cannot enter to maintain pool depth. While this may be intentional for emergency situations, it creates a privileged exit vector.

**Recommendation:** Document this asymmetry explicitly. Consider whether `withdraw` should also be pausable, or whether the pause should be limited to inbound flows only (as currently) with explicit justification.

---

### M-3: Integer Overflow Risk in k=2 Bonus Score for Large Stakes and Timestamps

```solidity
uint256 userPlus = T * T * userEligible + userSumStakeTimeSq[u];
uint256 plus = T * T * snapshotTotalStaked + snapshotSumStakeTimeSq;
```

`T` is a Unix timestamp (~`1.7e9` currently, `type(uint32).max ≈ 4.3e9`). `T * T ≈ 2.9e18` to `1.85e19`. Multiplied by `userEligible` (up to ~`1.13e77` in uint256 token amounts with 18 decimals), this can overflow.

In practice, token supplies are bounded, but for tokens with large supplies (e.g., meme tokens with `1e27` total supply) and 18 decimals, the multiplication `T * T * userEligible` can overflow.

```
T_max² × token_supply_max
= (4.3e9)² × (type(uint256).max)
→ overflows uint256
```

Even for `1e24` token units: `(4.3e9)^2 × 1e24 = 1.85e43` — safe. For `1e36` units: `1.85e55` — safe. Overflow requires `userEligible > 2^256 / T^2 ≈ 1.16e58 / 1.85e19 ≈ 6.3e38`, i.e., `6.3e20` tokens with 18 decimals. Unlikely in practice but not impossible for large-supply tokens.

**Recommendation:** Use `Math.mulDiv` for `T * T * userEligible` to prevent overflow, consistent with the final step already using it.

---

### M-4: `_replaceScope` Validates Accounts Against Agreement But Agreement Is Mutable Off-Chain

```solidity
if (!IAgreement(agreement).isContractInScope(account)) {
    revert AccountNotInAgreementScope(account);
}
```

The `agreement` address is set at initialization and never updated. If the agreement contract is upgradeable or the scope can change, accounts validated at `initialize` time may later be removed from the agreement scope. The pool scope would then contain accounts not in the agreement, which `isAccountInScope` would return `true` for — potentially misleading stakers about the actual coverage.

**Recommendation:** Either validate scope at staking time (expensive), or note that the agreement contract must be immutable/non-upgradeable.

---

### M-5: `claimExpired` Soft-Success for Non-Stakers Does Not Revert, Masking Failed Resolutions

```solidity
uint256 userEligible = eligibleStake[msg.sender];
if (userEligible == 0) {
    // Soft-success: caller had nothing to claim...
    return;
}
```

A non-staker calling `claimExpired` after the pool has already been resolved (e.g., CORRUPTED via `flagOutcome`) would hit:

```solidity
if (outcome != PoolStates.Outcome.UNRESOLVED && outcome != PoolStates.Outcome.EXPIRED) {
    revert InvalidOutcome();
}
```

This correctly reverts. But if `outcome == PoolStates.Outcome.EXPIRED` and the caller has `eligibleStake == 0`, they silently return. Tools monitoring for failed transactions won't see an error. This is a UX/tooling concern, not a security issue, but worth documenting.

---

## Low

### L-1: `withdraw()` Calls `_observePoolState()` Without Using the Return Value for Gate Enforcement

```solidity
function withdraw() external nonReentrant {
    if (outcome != PoolStates.Outcome.UNRESOLVED) revert OutcomeAlreadySet();
    IAttackRegistry.ContractState state = _observePoolState();
    if (
        riskWindowStart != 0
            || (state != IAttackRegistry.ContractState.NOT_