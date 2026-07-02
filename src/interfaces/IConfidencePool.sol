// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolStates} from "src/libraries/PoolStates.sol";

interface IConfidencePool {
    event Staked(address indexed staker, uint256 amount);
    event BonusContributed(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed staker, uint256 amount);
    /// @dev `moderator` is the caller of `flagOutcome`, or `address(0)` when the outcome was
    /// auto-resolved at expiry via `claimExpired` (mechanical, no human decision-maker).
    event OutcomeFlagged(address indexed moderator, PoolStates.Outcome outcome, bool goodFaith, address attacker);
    event ClaimSurvived(address indexed staker, uint256 principal, uint256 bonusShare);
    event ClaimCorrupted(address indexed caller, address indexed recoveryAddress, uint256 amount);
    event AttackerBountyClaimed(
        address indexed attacker, uint256 amount, uint256 totalClaimed, uint256 totalEntitlement
    );
    event UnclaimedCorruptedSwept(address indexed caller, address indexed recoveryAddress, uint256 amount);
    event BonusSwept(address indexed caller, address indexed recoveryAddress, uint256 amount);
    event ClaimExpired(address indexed staker, uint256 principal, uint256 bonusShare);
    event RecoveryAddressUpdated(address indexed oldAddr, address indexed newAddr);
    event ExpiryUpdated(uint256 oldExpiry, uint256 newExpiry);
    /// @dev Emitted whenever the pool owner replaces the scope before lock. Carries the full
    /// BattleChain account list so indexers can reconstruct scope without follow-up view calls.
    event ScopeUpdated(address[] accounts);
    /// @dev Emitted exactly once, on the first interaction that observes the agreement registry
    /// in a state other than NOT_DEPLOYED or NEW_DEPLOYMENT (i.e. once the agreement has moved
    /// past pre-attack staging). After this, the pool's scope is immutable.
    event ScopeLocked(uint256 timestamp);
    /// @dev Emitted exactly once, on the first interaction that observes the agreement registry
    /// in an active-risk state (UNDER_ATTACK or PROMOTION_REQUESTED). Terminal states
    /// (PRODUCTION, CORRUPTED) do NOT open the risk window — see the "no observable risk" rule
    /// in the contract natspec. Marks the lower bound of the stake-seconds accrual interval.
    event RiskWindowStarted(uint256 timestamp);
    /// @dev Emitted exactly once, on the first interaction that observes the agreement registry
    /// in a terminal state (PRODUCTION or CORRUPTED). Marks the upper bound `T` used in the
    /// k=2 bonus score, so the resolving call's block timestamp can't shift bonus shares.
    event RiskWindowEnded(uint256 timestamp);

    error PoolPaused();
    error PoolNotPaused();
    error InvalidAmount();
    error NoTokensReceived();
    error BelowMinStake();
    error StakingClosed();
    error OutcomeAlreadySet();
    error OutcomeNotSet();
    error InvalidOutcome();
    error NotModerator();
    error NotAttacker();
    error BountyAlreadyClaimed();
    error InvalidGoodFaithParams();
    error WithdrawsDisabled();
    error ExpiryLocked();
    error ExpiryTooSoon();
    error ExpiryTooFar();
    error InvalidRecoveryAddress();
    error PoolNotExpired();
    error InvalidAgreement();
    error ZeroAddress();
    error MustClaimBountyFirst();
    error ClaimWindowExpired();
    error ClaimWindowNotExpired();
    error NothingToSweep();
    error OutcomeNotEligibleForSweep();
    error NotGoodFaithCorrupted();
    error AgreementCorruptedAwaitingModerator();
    error EmptyScope();
    error AccountNotInAgreementScope(address account);
    error DuplicateAccount(address account);
    error ScopePostLockImmutable();
    error RiskWindowNotReached();

    function initialize(
        address agreement,
        address stakeToken,
        address safeHarborRegistry,
        address outcomeModerator,
        uint256 expiry,
        uint256 minStake,
        address recoveryAddress,
        address owner,
        address[] calldata accounts
    ) external;

    /// @dev Replaces the pool scope. Owner-only. Each account must be in the underlying
    /// agreement's BattleChain scope (`IAgreement.isContractInScope`). Reverts with
    /// `ScopePostLockImmutable` once the registry has transitioned past pre-attack staging.
    function setPoolScope(address[] calldata accounts) external;

    /// @dev Returns the BattleChain accounts currently in pool scope.
    function getScopeAccounts() external view returns (address[] memory);

    function isAccountInScope(address account) external view returns (bool);

    function scopeLocked() external view returns (bool);

    /// @dev Timestamp of the first observation of the registry in an active-risk state
    /// (UNDER_ATTACK or PROMOTION_REQUESTED). Zero before observation; terminal states do NOT
    /// seal it. Lower bound of the stake-seconds accrual interval.
    function riskWindowStart() external view returns (uint32);

    /// @dev Timestamp of the first observation of the registry in a terminal state (PRODUCTION
    /// or CORRUPTED). Zero before observation. Used as the upper bound `T` in the k=2 bonus
    /// score so the resolving call's block timestamp can't shift bonus distribution.
    function riskWindowEnd() external view returns (uint32);

    /// @dev Permissionless. No-ops once the pool is resolved (`outcome != UNRESOLVED`): the
    /// snapshot globals are frozen at resolution, so the risk-window markers must be too. While
    /// the pool is still UNRESOLVED, seals `riskWindowStart` at `block.timestamp` if the registry
    /// is in an active-risk state (UNDER_ATTACK or PROMOTION_REQUESTED) and the start hasn't been
    /// observed yet; *also* seals `riskWindowEnd` at `block.timestamp` if the registry is in a
    /// terminal state (PRODUCTION or CORRUPTED) and the end hasn't been observed yet. Reverts
    /// `RiskWindowNotReached` only pre-resolution when there is nothing to do AND the registry is
    /// pre-risk; otherwise no-ops silently. Allowed while paused (purely additive — marks
    /// timestamps, no funds move).
    function pokeRiskWindow() external;

    /// @dev Credits only tokens actually received. Stake is immediately at-risk and accruing —
    /// there is no maturation cliff. Bonus credit only begins once the registry enters an
    /// active-risk state (UNDER_ATTACK or PROMOTION_REQUESTED — see `riskWindowStart`).
    function stake(uint256 amount) external;

    function contributeBonus(uint256 amount) external;

    /// @dev Drains the caller's full eligible stake and transfers to the caller in a single call.
    /// Allowed only while the registry is in a pre-attack state (`NOT_DEPLOYED`, `NEW_DEPLOYMENT`,
    /// or `ATTACK_REQUESTED`); reverts with `WithdrawsDisabled` once the agreement is
    /// `UNDER_ATTACK` or beyond. Withdrawing before flagOutcome forfeits the caller's bonus claim.
    function withdraw() external;

    /// @dev Snapshots `totalEligibleStake`, `totalBonus`, `sumStakeTime`, and `sumStakeTimeSq`.
    /// Bonus is distributed by the k=2 weighted-average formula: each user's share is
    /// proportional to `stake × (T − entryTime[u])²` where `T = outcomeFlaggedAt`.
    function flagOutcome(PoolStates.Outcome outcome, bool goodFaith, address attacker) external;

    /// @dev Pays `eligibleStake + pro-rata bonus`. Bonus share is proportional to
    /// `eligibleStake[caller] × (outcomeFlaggedAt − entryTime[caller])²` divided by the global
    /// k=2 score; falls back to amount-weighted when no at-risk time elapsed.
    function claimSurvived() external;

    /// @dev Sweeps the pool's full token balance to `recoveryAddress`. For good-faith CORRUPTED,
    /// reverts with `MustClaimBountyFirst` until the attacker has fully claimed their bounty;
    /// after that, sweeps whatever remains. Repeat-callable so post-resolution donations into
    /// the pool can also be recovered.
    function claimCorrupted() external;

    function claimAttackerBounty() external;

    function sweepUnclaimedCorrupted() external;

    function sweepUnclaimedBonus() external;

    /// @dev Auto-finalizes outcome at the first call post-expiry: PRODUCTION → SURVIVED,
    /// CORRUPTED (with an observed risk window, after `expiry + MODERATOR_CORRUPTED_GRACE`) →
    /// bad-faith CORRUPTED, otherwise → EXPIRED. The SURVIVED and EXPIRED branches pay the
    /// caller `eligibleStake + bonusShare` using the same k=2 formula as `claimSurvived`; the
    /// CORRUPTED branch only flips state (pool funds then move via `claimCorrupted`) and pays
    /// the caller nothing. Non-stakers can call to mechanically resolve the pool.
    function claimExpired() external;

    function setRecoveryAddress(address newRecoveryAddress) external;

    function setExpiry(uint256 newExpiry) external;

    function pause() external;

    function unpause() external;

    function corruptedReserve() external view returns (uint256);

    function bountyClaimed() external view returns (uint256);

    function bountyEntitlement() external view returns (uint256);

    function CORRUPTED_CLAIM_WINDOW() external view returns (uint256);

    function MODERATOR_CORRUPTED_GRACE() external view returns (uint256);

    function corruptedClaimDeadline() external view returns (uint32);

    function recoveryAddress() external view returns (address);
}
