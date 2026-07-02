// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {PoolStates} from "src/libraries/PoolStates.sol";
import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {IBattleChainSafeHarborRegistry} from "@battlechain/interface/IBattleChainSafeHarborRegistry.sol";
import {IAgreement} from "@battlechain/interface/IAgreement.sol";

/**
 * @title ConfidencePool
 * @notice BattleChain confidence pool clone implementation.
 * @dev Design decisions, trust assumptions, and known/intentional behavior are documented in
 *      docs/DESIGN.md. Auditors: check a suspected finding against that document before
 *      reporting — several behaviors here are deliberate and accepted (notably the registry-state
 *      vocabulary: `UNDER_ATTACK`/`PROMOTION_REQUESTED` mean "legally attackable," not "breached").
 *
 *      Quick reference (full rationale in docs/DESIGN.md):
 *      - The sponsor controls `recoveryAddress`, `expiry` (until the first stake), and pool scope
 *        (until the registry leaves pre-attack staging). All staker-relevant state is on-chain.
 *      - CORRUPTED resolution: (1) bad-faith sweeps the full pool to `recoveryAddress` via
 *        `claimCorrupted`; (2) good-faith entitles the named attacker to the full pool via
 *        `claimAttackerBounty` within `CORRUPTED_CLAIM_WINDOW`, remainder swept after;
 *        (3) permissionless scope-blind auto-resolve via `claimExpired` after
 *        `expiry + MODERATOR_CORRUPTED_GRACE`.
 *      - Bonus is k=2 time-weighted (`amount × (T − entryTime)²`), summed per-deposit; entry
 *        floored at `riskWindowStart`, `T` = first-observed terminal moment (or `expiry`).
 *      - `withdraw()` is allowed until the registry reaches `UNDER_ATTACK`, then permanently
 *        disabled (gated on the one-way `riskWindowStart != 0` latch).
 */
// aderyn-ignore-next-line(centralization-risk)
contract ConfidencePool is Initializable, Ownable2Step, ReentrancyGuard, Pausable, IConfidencePool {
    using SafeERC20 for IERC20;

    uint256 private constant _MIN_EXPIRY_LEAD = 30 days;
    uint256 public constant override CORRUPTED_CLAIM_WINDOW = 180 days;
    /// @notice Grace period after `expiry` during which only the moderator can resolve a CORRUPTED
    /// registry. After it elapses, any caller can finalize as bad-faith CORRUPTED via `claimExpired`
    /// (the sweep to `recoveryAddress` then goes through `claimCorrupted`). Backstop against a
    /// permanently-unavailable moderator; under the DAO-moderator trust model it should never fire.
    /// @dev This backstop is scope-blind and staker-pessimistic, and its `riskWindowStart != 0`
    /// gate is permissionlessly sealable (via `pokeRiskWindow`) by design — both intentional, with
    /// accepted consequences documented in docs/DESIGN.md (auto-CORRUPTED backstop).
    uint256 public constant override MODERATOR_CORRUPTED_GRACE = 180 days;

    // Config (set at init; `expiry`/`recoveryAddress`/scope mutable per their own gates).
    //
    // Timestamps are `uint32` seconds, packed with addresses. uint32 saturates on 2106-02-07;
    // expiry-derived timestamps are bounded by `expiry` (guarded at its setters), CORRUPTED-path
    // ones by `block.timestamp + 180 days`. Every multiply into the k=2 score widens to uint256
    // first (see `_bonusShare`, `_markRiskWindow*`, `_clampUserSums`).
    address public agreement;
    IERC20 public stakeToken;
    IBattleChainSafeHarborRegistry public safeHarborRegistry;
    address public outcomeModerator;
    address public override recoveryAddress;

    uint256 public minStake;
    /// @notice Pool deadline. Past it, staking closes and `claimExpired` can mechanically resolve.
    uint32 public expiry;

    /// @notice Enumerable list of BattleChain accounts in pool scope.
    address[] internal _scopeAccounts;
    /// @notice O(1) membership lookup. True if `account` is in the pool's BattleChain scope.
    mapping(address account => bool inScope) public override isAccountInScope;
    /// @notice One-way flag flipped on the first interaction that observes the registry in any
    /// state other than NOT_DEPLOYED or NEW_DEPLOYMENT (i.e. the agreement has moved past
    /// pre-attack staging). Once true, the scope can no longer be changed.
    bool public override scopeLocked;

    // Live stake accounting (maintained incrementally on stake/withdraw).
    uint256 public totalEligibleStake;
    uint256 public totalBonus;
    mapping(address staker => uint256 amount) public eligibleStake;
    /// @notice Per-user Σ deposit_i.amount × deposit_i.entryTime. Pair with `userSumStakeTimeSq`
    /// to compute the user's k=2 score in O(1) at claim time.
    mapping(address staker => uint256 sum) public userSumStakeTime;
    /// @notice Per-user Σ deposit_i.amount × deposit_i.entryTime². See `userSumStakeTime`.
    mapping(address staker => uint256 sum) public userSumStakeTimeSq;
    /// @notice Σ eligibleStake_u × entryTime_u across all users, maintained incrementally on
    /// stake/withdraw. Together with `sumStakeTimeSq` and `totalEligibleStake`, computes the
    /// k=2 bonus-distribution denominator in O(1) at claim time:
    ///   globalScore = T² × totalEligibleStake − 2T × sumStakeTime + sumStakeTimeSq
    /// where T is `outcomeFlaggedAt`. Eagerly reset to `totalEligibleStake × riskWindowStart`
    /// at the moment the risk window opens, so pre-risk parked capital earns no bonus credit.
    uint256 public sumStakeTime;
    /// @notice Σ eligibleStake_u × entryTime_u² across all users. See `sumStakeTime`.
    uint256 public sumStakeTimeSq;

    // Risk-window markers (one-way registry observations; see `_observePoolState`).
    /// @notice Timestamp at which the registry was first observed in an active-risk state
    /// (UNDER_ATTACK or PROMOTION_REQUESTED). Zero before the window opens. Bonus accrual treats
    /// every staker as if they entered at `riskWindowStart` at the earliest; pre-risk deposits
    /// earn no bonus credit. Observed lazily by gated entrypoints or eagerly via
    /// `pokeRiskWindow`. Capped at `expiry` so a late observation doesn't push the accrual lower
    /// bound above the bonus formula's upper bound `T`. See the contract-level natspec for the
    /// "no observable risk" rules that apply when this stays zero.
    uint32 public override riskWindowStart;
    /// @notice Timestamp at which the registry was first observed in a terminal state (PRODUCTION
    /// or CORRUPTED). Zero before observation. Acts as the upper bound `T` in the k=2 bonus
    /// score so callers can't shift bonus distribution by varying when they trigger the
    /// resolving call. Observed lazily or eagerly via `pokeRiskWindow`. Capped at `expiry`
    /// for the same reason as `riskWindowStart`: accrual is bounded by the pool's lifecycle.
    uint32 public override riskWindowEnd;

    // Resolution outcome (frozen at `flagOutcome` / `claimExpired` resolution).
    address public attacker;
    PoolStates.Outcome public outcome;
    bool public goodFaith;
    bool public expiryLocked;
    /// @notice Flipped true on the first successful post-resolution claim/sweep. Locks the
    /// outcome against moderator re-flagging once any participant has acted on it.
    bool public claimsStarted;
    /// @notice The upper bound `T` used in the k=2 bonus formula. Set at outcome resolution to
    /// `riskWindowEnd` for SURVIVED / CORRUPTED resolutions or `expiry` for EXPIRED. Pinned to
    /// the first-observed terminal moment so the resolving call's `block.timestamp` can't shift
    /// bonus shares.
    uint32 public outcomeFlaggedAt;

    // Resolution snapshot (live accounting captured at resolution; bonus-distribution inputs).
    uint256 public snapshotTotalStaked;
    uint256 public snapshotTotalBonus;
    /// @notice `sumStakeTime` captured at `flagOutcome` time. Used in the bonus denominator.
    uint256 public snapshotSumStakeTime;
    /// @notice `sumStakeTimeSq` captured at `flagOutcome` time. Used in the bonus denominator.
    uint256 public snapshotSumStakeTimeSq;
    /// @notice Σ bonus shares paid to claimants so far. Subtracted from `snapshotTotalBonus`
    /// to compute the bonus still owed to non-claimers, used by `sweepUnclaimedBonus` to
    /// reserve their entitlement when sweeping excess (donations, dust).
    uint256 public claimedBonus;
    mapping(address staker => bool claimed) public hasClaimed;

    // CORRUPTED-path accounting (bounty + sweep bookkeeping).
    /// @notice CORRUPTED-path accounting marker tracking the snapshot amount destined for
    /// `recoveryAddress` (less anything the attacker has claimed in good-faith). Decremented
    /// opportunistically as `claimAttackerBounty` / `claimCorrupted` / `sweepUnclaimedCorrupted`
    /// move funds. Not load-bearing for sweep gating — those use `stakeToken.balanceOf` directly
    /// so post-resolution donations can be recovered.
    uint256 public corruptedReserve;
    uint256 public bountyClaimed;
    uint256 public bountyEntitlement;
    /// @notice `block.timestamp` of the first-ever good-faith CORRUPTED flag. Anchors
    /// `corruptedClaimDeadline` so the moderator cannot mint a fresh attacker-claim window by
    /// toggling the outcome out of and back into good-faith CORRUPTED. Set once, never reset.
    uint32 internal _firstGoodFaithCorruptedAt;
    uint32 public override corruptedClaimDeadline;

    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    // aderyn-ignore-next-line(modifier-used-only-once)
    modifier onlyModerator() {
        if (msg.sender != outcomeModerator) revert NotModerator();
        _;
    }

    modifier whenPoolNotPaused() {
        if (paused()) revert PoolPaused();
        _;
    }

    // aderyn-ignore-next-line(modifier-used-only-once)
    modifier whenPoolPaused() {
        if (!paused()) revert PoolNotPaused();
        _;
    }

    /// @inheritdoc IConfidencePool
    function initialize(
        address agreement_,
        address stakeToken_,
        address safeHarborRegistry_,
        address outcomeModerator_,
        uint256 expiry_,
        uint256 minStake_,
        address recoveryAddress_,
        address owner_,
        address[] calldata accounts
    ) external initializer {
        if (agreement_ == address(0)) revert ZeroAddress();
        if (stakeToken_ == address(0)) revert ZeroAddress();
        if (safeHarborRegistry_ == address(0)) revert ZeroAddress();
        if (outcomeModerator_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();
        if (recoveryAddress_ == address(0)) revert InvalidRecoveryAddress();
        if (expiry_ < block.timestamp + _MIN_EXPIRY_LEAD) revert ExpiryTooSoon();
        if (expiry_ > type(uint32).max) revert ExpiryTooFar();
        if (minStake_ == 0) revert InvalidAmount();
        // aderyn-fp-next-line(reentrancy-state-change)
        if (!IBattleChainSafeHarborRegistry(safeHarborRegistry_).isAgreementValid(agreement_)) {
            revert InvalidAgreement();
        }

        agreement = agreement_;
        stakeToken = IERC20(stakeToken_);
        safeHarborRegistry = IBattleChainSafeHarborRegistry(safeHarborRegistry_);
        outcomeModerator = outcomeModerator_;
        // forge-lint: disable-next-line(unsafe-typecast)
        expiry = uint32(expiry_);
        minStake = minStake_;
        recoveryAddress = recoveryAddress_;
        outcome = PoolStates.Outcome.UNRESOLVED;

        _replaceScope(accounts);

        // Direct assignment (skipping Ownable2Step's two-step) so no `owner() == initializer-caller`
        // window exists between init and the new owner accepting. Two-step still applies to later transfers.
        _transferOwnership(owner_);
    }

    /// @inheritdoc IConfidencePool
    function stake(uint256 amount) external nonReentrant whenPoolNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (amount < minStake) revert BelowMinStake();
        if (outcome != PoolStates.Outcome.UNRESOLVED) revert OutcomeAlreadySet();
        if (block.timestamp >= expiry) revert StakingClosed();
        _assertDepositsAllowed(_observePoolState());

        if (!expiryLocked) {
            expiryLocked = true;
        }

        // Balance-diff defense-in-depth against the factory allowlist admitting a fee-on-transfer
        // or rebasing token (governance error, or a proxy-token upgrade post-allowlist).
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 balanceAfter = stakeToken.balanceOf(address(this));
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received == 0) revert NoTokensReceived();
        if (received < minStake) revert BelowMinStake();

        _clampUserSums(msg.sender);

        // Pre-risk deposits use wall clock and get promoted to riskWindowStart later via
        // `_clampUserSums`; post-risk deposits go in at wall clock (already ≥ riskWindowStart).
        uint256 newEntry = block.timestamp;
        uint256 start = riskWindowStart;
        if (start != 0 && newEntry < start) newEntry = start;

        uint256 contribTime = received * newEntry;
        uint256 contribTimeSq = received * newEntry * newEntry;

        eligibleStake[msg.sender] += received;
        userSumStakeTime[msg.sender] += contribTime;
        userSumStakeTimeSq[msg.sender] += contribTimeSq;
        totalEligibleStake += received;
        sumStakeTime += contribTime;
        sumStakeTimeSq += contribTimeSq;

        emit Staked(msg.sender, received);
    }

    /// @inheritdoc IConfidencePool
    function contributeBonus(uint256 amount) external nonReentrant whenPoolNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (outcome != PoolStates.Outcome.UNRESOLVED) revert OutcomeAlreadySet();
        if (block.timestamp >= expiry) revert StakingClosed();

        _assertDepositsAllowed(_observePoolState());

        // Balance-diff defense-in-depth — see `stake`.
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 balanceAfter = stakeToken.balanceOf(address(this));
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received == 0) revert NoTokensReceived();

        totalBonus += received;

        emit BonusContributed(msg.sender, received);
    }

    /// @inheritdoc IConfidencePool
    function withdraw() external nonReentrant {
        if (outcome != PoolStates.Outcome.UNRESOLVED) revert OutcomeAlreadySet();
        IAttackRegistry.ContractState state = _observePoolState();
        // `riskWindowStart` is the pool's one-way record that risk has materialised;
        // gate on it so an upstream registry rewind cannot re-open withdrawals.
        if (
            riskWindowStart != 0
                || (state != IAttackRegistry.ContractState.NOT_DEPLOYED
                    && state != IAttackRegistry.ContractState.NEW_DEPLOYMENT
                    && state != IAttackRegistry.ContractState.ATTACK_REQUESTED)
        ) {
            revert WithdrawsDisabled();
        }

        uint256 amount = eligibleStake[msg.sender];
        if (amount == 0) revert InvalidAmount();

        _clampUserSums(msg.sender);
        // Withdrawing forfeits the caller's bonus claim: subtract their full contribution from
        // the global accumulators so honest stakers' shares aren't diluted by the exiter's
        // forfeited weight.
        sumStakeTime -= userSumStakeTime[msg.sender];
        sumStakeTimeSq -= userSumStakeTimeSq[msg.sender];

        eligibleStake[msg.sender] = 0;
        userSumStakeTime[msg.sender] = 0;
        userSumStakeTimeSq[msg.sender] = 0;
        totalEligibleStake -= amount;

        stakeToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @inheritdoc IConfidencePool
    function flagOutcome(PoolStates.Outcome newOutcome, bool goodFaith_, address attacker_) external onlyModerator {
        // Re-flag allowed pre-claim so the moderator can fix a typo'd outcome / attacker before
        // any participant locks in the wrong distribution. The window closing on the FIRST claim
        // (`claimsStarted`) is by design — a value-movement finality latch, not a front-runnable
        // moderator privilege. See docs/DESIGN.md (re-flag window).
        if (outcome != PoolStates.Outcome.UNRESOLVED && claimsStarted) revert OutcomeAlreadySet();
        IAttackRegistry.ContractState state = _observePoolState();

        if (newOutcome == PoolStates.Outcome.SURVIVED) {
            if (goodFaith_ || attacker_ != address(0)) {
                revert InvalidGoodFaithParams();
            }
            // SURVIVED accepts either terminal registry state: PRODUCTION (agreement-level
            // survival) or CORRUPTED (the agreement was breached but the vulnerability was
            // outside this pool's committed scope — the moderator's off-chain judgement against
            // the published BattleChain account list).
            if (state != IAttackRegistry.ContractState.PRODUCTION && state != IAttackRegistry.ContractState.CORRUPTED) {
                revert InvalidOutcome();
            }
        } else if (newOutcome == PoolStates.Outcome.CORRUPTED) {
            if (!goodFaith_) {
                if (attacker_ != address(0)) revert InvalidGoodFaithParams();
            } else {
                if (attacker_ == address(0)) revert InvalidGoodFaithParams();
            }
            if (state != IAttackRegistry.ContractState.CORRUPTED) revert InvalidOutcome();
        } else {
            revert InvalidOutcome();
        }

        bool willBeGoodFaithCorrupted = newOutcome == PoolStates.Outcome.CORRUPTED && goodFaith_;

        outcome = newOutcome;
        goodFaith = goodFaith_;
        attacker = attacker_;
        snapshotTotalStaked = totalEligibleStake;
        snapshotTotalBonus = totalBonus;
        snapshotSumStakeTime = sumStakeTime;
        snapshotSumStakeTimeSq = sumStakeTimeSq;
        corruptedReserve = newOutcome == PoolStates.Outcome.CORRUPTED ? snapshotTotalStaked + snapshotTotalBonus : 0;
        bountyEntitlement = willBeGoodFaithCorrupted ? snapshotTotalStaked + snapshotTotalBonus : 0;
        if (willBeGoodFaithCorrupted) {
            if (_firstGoodFaithCorruptedAt == 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                _firstGoodFaithCorruptedAt = uint32(block.timestamp);
            }
            // Reuses the original window on re-entry — which may already be in the past, leaving
            // nothing to claim. Intended: the deadline must never be extendable.
            // Sum stays in uint32 unless flagged within 180 days of the 2106 ceiling; out of scope.
            // forge-lint: disable-next-line(unsafe-typecast)
            corruptedClaimDeadline = uint32(_firstGoodFaithCorruptedAt + CORRUPTED_CLAIM_WINDOW);
        } else {
            corruptedClaimDeadline = 0;
        }
        outcomeFlaggedAt = riskWindowEnd;

        emit OutcomeFlagged(msg.sender, newOutcome, goodFaith_, attacker_);
    }

    /// @inheritdoc IConfidencePool
    function claimSurvived() external nonReentrant {
        if (outcome != PoolStates.Outcome.SURVIVED) revert OutcomeNotSet();
        if (hasClaimed[msg.sender]) revert InvalidAmount();

        uint256 userEligible = eligibleStake[msg.sender];
        if (userEligible == 0) revert InvalidAmount();

        _clampUserSums(msg.sender);

        hasClaimed[msg.sender] = true;

        uint256 bonusShare = _bonusShare(msg.sender, userEligible);
        uint256 payout = userEligible + bonusShare;
        totalEligibleStake -= userEligible;
        claimedBonus += bonusShare;

        delete eligibleStake[msg.sender];
        delete userSumStakeTime[msg.sender];
        delete userSumStakeTimeSq[msg.sender];

        if (!claimsStarted) claimsStarted = true;
        stakeToken.safeTransfer(msg.sender, payout);
        emit ClaimSurvived(msg.sender, userEligible, bonusShare);
    }

    /// @inheritdoc IConfidencePool
    function claimCorrupted() external nonReentrant {
        if (outcome != PoolStates.Outcome.CORRUPTED) revert OutcomeNotSet();
        if (goodFaith && bountyClaimed < bountyEntitlement) revert MustClaimBountyFirst();

        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 toSweep = stakeToken.balanceOf(address(this));
        if (toSweep == 0) revert NothingToSweep();

        // Clamp the decrement — `toSweep` can exceed the original reserve when post-resolution
        // donations have inflated the balance.
        corruptedReserve = toSweep <= corruptedReserve ? corruptedReserve - toSweep : 0;
        if (!goodFaith) {
            bountyClaimed = bountyEntitlement;
        }
        if (!claimsStarted) claimsStarted = true;
        stakeToken.safeTransfer(recoveryAddress, toSweep);

        emit ClaimCorrupted(msg.sender, recoveryAddress, toSweep);
    }

    /// @inheritdoc IConfidencePool
    /// @dev Pays `min(remaining, freeBalance)` — the full remaining entitlement (the whole pool
    /// for good-faith CORRUPTED), not a caller-chosen partial. Bounty/sweep gating rationale:
    /// docs/DESIGN.md (CORRUPTED bounty mechanics).
    function claimAttackerBounty() external nonReentrant {
        if (outcome != PoolStates.Outcome.CORRUPTED) revert OutcomeNotSet();
        if (bountyClaimed == bountyEntitlement) revert BountyAlreadyClaimed();
        if (!goodFaith) revert InvalidGoodFaithParams();
        if (msg.sender != attacker) revert NotAttacker();
        if (block.timestamp > corruptedClaimDeadline) revert ClaimWindowExpired();

        uint256 remaining = bountyEntitlement - bountyClaimed;
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 freeBalance = stakeToken.balanceOf(address(this));
        uint256 payout = remaining <= freeBalance ? remaining : freeBalance;

        uint256 newBountyClaimed = bountyClaimed + payout;
        bountyClaimed = newBountyClaimed;
        if (payout > 0) {
            corruptedReserve -= payout;
            if (!claimsStarted) claimsStarted = true;
            stakeToken.safeTransfer(attacker, payout);
        }

        emit AttackerBountyClaimed(attacker, payout, newBountyClaimed, bountyEntitlement);
    }

    /// @inheritdoc IConfidencePool
    function sweepUnclaimedCorrupted() external nonReentrant {
        if (outcome != PoolStates.Outcome.CORRUPTED) revert OutcomeNotSet();
        if (!goodFaith) revert NotGoodFaithCorrupted();
        if (block.timestamp <= corruptedClaimDeadline) revert ClaimWindowNotExpired();

        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 amount = stakeToken.balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();

        corruptedReserve = 0;
        bountyClaimed = bountyEntitlement;
        if (!claimsStarted) claimsStarted = true;
        stakeToken.safeTransfer(recoveryAddress, amount);

        emit UnclaimedCorruptedSwept(msg.sender, recoveryAddress, amount);
    }

    /// @inheritdoc IConfidencePool
    function sweepUnclaimedBonus() external nonReentrant {
        if (outcome != PoolStates.Outcome.SURVIVED && outcome != PoolStates.Outcome.EXPIRED) {
            revert OutcomeNotEligibleForSweep();
        }

        // Reserve principal still owed to non-claimers plus any bonus they're entitled to. When
        // `riskWindowStart == 0` (no observable risk), `_bonusShare` returns 0 for everyone, so
        // the bonus is not owed to any staker and the entire snapshotTotalBonus is sweepable.
        uint256 reserved;
        if (totalEligibleStake != 0) {
            reserved = totalEligibleStake;
            if (riskWindowStart != 0) {
                reserved += snapshotTotalBonus - claimedBonus;
            }
        }

        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 freeBalance = stakeToken.balanceOf(address(this));
        uint256 amount = freeBalance > reserved ? freeBalance - reserved : 0;
        if (amount == 0) revert NothingToSweep();

        // Bonus is only unreserved when no staker is owed it (no risk window, or no stakers left).
        // In that case the sweep removes it from the pool, so drop it from the live `totalBonus`
        // too — keeping the accounting honest for any later re-snapshot. Clamp to `totalBonus` so
        // swept donations/dust (never counted in it) can't over-decrement or underflow.
        if (totalEligibleStake == 0 || riskWindowStart == 0) {
            totalBonus -= amount <= totalBonus ? amount : totalBonus;
        }

        // Intentionally does NOT set claimsStarted. A direct-transfer donation of as little as 1
        // wei would otherwise let anyone flip the flag post-flagOutcome and block the moderator's
        // documented pre-claim re-flag window. Genuine reliance only comes from claim entrypoints.
        stakeToken.safeTransfer(recoveryAddress, amount);

        emit BonusSwept(msg.sender, recoveryAddress, amount);
    }

    /// @inheritdoc IConfidencePool
    function claimExpired() external nonReentrant {
        if (block.timestamp < expiry) revert PoolNotExpired();
        if (outcome != PoolStates.Outcome.UNRESOLVED && outcome != PoolStates.Outcome.EXPIRED) {
            revert InvalidOutcome();
        }

        if (outcome == PoolStates.Outcome.UNRESOLVED) {
            // Read the registry only while resolving. Post-resolution observation would (a) gate
            // principal withdrawal on registry liveness, and (b) re-open `_markRiskWindowStart`,
            // which clamps later claimers' per-user sums against a riskWindowStart that diverges
            // from the already-frozen global snapshot — collapsing their bonus numerator to zero.
            IAttackRegistry.ContractState state = _observePoolState();
            snapshotTotalStaked = totalEligibleStake;
            snapshotTotalBonus = totalBonus;
            snapshotSumStakeTime = sumStakeTime;
            snapshotSumStakeTimeSq = sumStakeTimeSq;

            // address(0) moderator marks a mechanical auto-resolution (no decision-maker).
            // Auto-CORRUPTED requires both registry CORRUPTED and an observed risk window;
            // otherwise falls through to EXPIRED (returns principal).
            if (state == IAttackRegistry.ContractState.CORRUPTED && riskWindowStart != 0) {
                // Scope-blind by design: this forces CORRUPTED for any corrupted agreement, even
                // one whose breach was out-of-scope (where the moderator would have flagged
                // SURVIVED). See MODERATOR_CORRUPTED_GRACE for the trust assumption this encodes.
                // Moderator is the canonical decision-maker for CORRUPTED (only they can name
                // an attacker for the good-faith bounty path). Defer to them during the grace
                // window; after that, anyone can finalize as bad-faith CORRUPTED so funds aren't
                // trapped if the DAO becomes permanently unavailable.
                if (block.timestamp < expiry + MODERATOR_CORRUPTED_GRACE) {
                    revert AgreementCorruptedAwaitingModerator();
                }
                outcome = PoolStates.Outcome.CORRUPTED;
                outcomeFlaggedAt = riskWindowEnd;
                corruptedReserve = snapshotTotalStaked + snapshotTotalBonus;
                // Lock the outcome so the moderator can't override mechanical bad-faith CORRUPTED
                // with good-faith naming an attacker — that would redirect the full pool from
                // recoveryAddress to the named address via claimAttackerBounty.
                claimsStarted = true;
                emit OutcomeFlagged(address(0), PoolStates.Outcome.CORRUPTED, false, address(0));
                // Bad-faith CORRUPTED pays nothing to the caller; the full sweep happens via
                // claimCorrupted. Return early so the SURVIVED/EXPIRED claim flow below stays
                // dormant.
                return;
            }

            if (state == IAttackRegistry.ContractState.PRODUCTION) {
                outcome = PoolStates.Outcome.SURVIVED;
                outcomeFlaggedAt = riskWindowEnd;
                emit OutcomeFlagged(address(0), PoolStates.Outcome.SURVIVED, false, address(0));
            } else {
                // Reached for EVERY non-terminal state, including active-risk (UNDER_ATTACK /
                // PROMOTION_REQUESTED). Intentional, NOT a missing active-risk deferral: expiring
                // while still attackable means the agreement survived the term, so EXPIRED
                // (principal + bonus returned) is correct. See docs/DESIGN.md (EXPIRED resolution).
                outcome = PoolStates.Outcome.EXPIRED;
                // EXPIRED has no terminal registry observation; `expiry` is the pool's own
                // deadline and is fixed at init/lock time, so it's grief-proof as the upper bound.
                outcomeFlaggedAt = expiry;
                emit OutcomeFlagged(address(0), PoolStates.Outcome.EXPIRED, false, address(0));
            }
            // Defense-in-depth: mirror the auto-CORRUPTED lock above so finality of mechanical
            // resolution is uniform across all three branches and doesn't depend on the
            // registry's one-way state machine to block a later moderator override.
            claimsStarted = true;
        }

        if (hasClaimed[msg.sender]) revert InvalidAmount();

        uint256 userEligible = eligibleStake[msg.sender];
        if (userEligible == 0) {
            // Soft-success: caller had nothing to claim, but the outcome is now terminal —
            // useful for a non-staker to mechanically auto-resolve the pool post-expiry.
            return;
        }

        _clampUserSums(msg.sender);

        hasClaimed[msg.sender] = true;

        uint256 bonusShare = _bonusShare(msg.sender, userEligible);
        uint256 payout = userEligible + bonusShare;
        totalEligibleStake -= userEligible;
        claimedBonus += bonusShare;

        delete eligibleStake[msg.sender];
        delete userSumStakeTime[msg.sender];
        delete userSumStakeTimeSq[msg.sender];

        if (!claimsStarted) claimsStarted = true;
        stakeToken.safeTransfer(msg.sender, payout);
        if (outcome == PoolStates.Outcome.SURVIVED) {
            emit ClaimSurvived(msg.sender, userEligible, bonusShare);
        } else {
            emit ClaimExpired(msg.sender, userEligible, bonusShare);
        }
    }

    /// @inheritdoc IConfidencePool
    // aderyn-ignore-next-line(centralization-risk)
    function setRecoveryAddress(address newRecoveryAddress) external onlyOwner {
        if (newRecoveryAddress == address(0)) revert InvalidRecoveryAddress();

        address oldRecoveryAddress = recoveryAddress;
        recoveryAddress = newRecoveryAddress;

        emit RecoveryAddressUpdated(oldRecoveryAddress, newRecoveryAddress);
    }

    /// @inheritdoc IConfidencePool
    // aderyn-ignore-next-line(centralization-risk)
    function setExpiry(uint256 newExpiry) external onlyOwner {
        if (expiryLocked) revert ExpiryLocked();
        if (newExpiry < block.timestamp + _MIN_EXPIRY_LEAD) revert ExpiryTooSoon();
        if (newExpiry > type(uint32).max) revert ExpiryTooFar();

        uint256 oldExpiry = expiry;
        // forge-lint: disable-next-line(unsafe-typecast)
        expiry = uint32(newExpiry);

        emit ExpiryUpdated(oldExpiry, newExpiry);
    }

    /// @inheritdoc IConfidencePool
    // aderyn-ignore-next-line(centralization-risk)
    function setPoolScope(address[] calldata accounts) external onlyOwner {
        // aderyn-ignore-next-line(unchecked-return)
        _observePoolState();
        if (scopeLocked) revert ScopePostLockImmutable();
        _replaceScope(accounts);
    }

    /// @inheritdoc IConfidencePool
    function getScopeAccounts() external view returns (address[] memory) {
        return _scopeAccounts;
    }

    /// @inheritdoc IConfidencePool
    function pokeRiskWindow() external {
        // No-op once resolved: the snapshot globals are frozen, so the risk-window markers must
        // be too.
        if (outcome != PoolStates.Outcome.UNRESOLVED) return;
        // Revert only when nothing has been sealed — registry never reached active risk or
        // a terminal state.
        // aderyn-ignore-next-line(unchecked-return)
        _observePoolState();
        if (riskWindowStart == 0 && riskWindowEnd == 0) revert RiskWindowNotReached();
    }

    /// @inheritdoc IConfidencePool
    // aderyn-ignore-next-line(centralization-risk)
    function pause() external onlyOwner whenPoolNotPaused {
        _pause();
    }

    /// @inheritdoc IConfidencePool
    // aderyn-ignore-next-line(centralization-risk)
    function unpause() external onlyOwner whenPoolPaused {
        _unpause();
    }

    /// @dev If the risk window has opened past one or more of the user's deposit entries,
    /// recompute their per-user sums as if every existing deposit entered at `riskWindowStart`.
    /// Idempotent: detected via `userSumStakeTime[u] < eligibleStake[u] × riskWindowStart`,
    /// which only holds pre-clamp. Does NOT update globals — they were eagerly reset in
    /// `_markRiskWindowStart` for all users present at that moment.
    function _clampUserSums(address u) internal {
        uint256 start = riskWindowStart;
        uint256 stake_ = eligibleStake[u];
        if (start == 0 || stake_ == 0) return;
        if (userSumStakeTime[u] < stake_ * start) {
            userSumStakeTime[u] = stake_ * start;
            userSumStakeTimeSq[u] = stake_ * start * start;
        }
    }

    /// @dev k=2 per-deposit bonus share:
    ///   userScore   = T²·eligibleStake[u] − 2T·userSumStakeTime[u] + userSumStakeTimeSq[u]
    ///   globalScore = T²·snapshotTotalStaked − 2T·snapshotSumStakeTime + snapshotSumStakeTimeSq
    ///   share       = userScore × snapshotTotalBonus / globalScore
    /// Falls back to amount-weighted when `globalScore == 0` (same-block flag, or a window first
    /// observed at/after `expiry` so every `(T − entry)` is zero). Distinct from the
    /// `riskWindowStart == 0` "no observable risk" rule below (which pays zero): here a window was
    /// observed so stakers are owed the bonus, but with no time spread to weight by, an
    /// amount-weighted split is the intended neutral fallback. See docs/DESIGN.md (bonus distribution).
    function _bonusShare(address u, uint256 userEligible) internal view returns (uint256) {
        if (snapshotTotalBonus == 0) return 0;
        // No observable risk → no bonus (see contract natspec).
        if (riskWindowStart == 0) return 0;
        uint256 T = outcomeFlaggedAt;

        // Underflow guards on both subtractions: globally the sum of squares is nonneg, but
        // truncation/rounding pathologies could push individual terms over.
        uint256 userPlus = T * T * userEligible + userSumStakeTimeSq[u];
        uint256 userMinus = 2 * T * userSumStakeTime[u];
        uint256 userScore = userPlus > userMinus ? userPlus - userMinus : 0;

        uint256 plus = T * T * snapshotTotalStaked + snapshotSumStakeTimeSq;
        uint256 minus = 2 * T * snapshotSumStakeTime;
        uint256 globalScore = plus > minus ? plus - minus : 0;

        if (globalScore == 0) {
            // No time elapsed in the risk window for anyone → fallback to amount-weighted.
            if (snapshotTotalStaked == 0) return 0;
            return Math.mulDiv(userEligible, snapshotTotalBonus, snapshotTotalStaked);
        }
        // mulDiv handles the final multiply-then-divide via 512-bit intermediates, so a very
        // large `snapshotTotalBonus` cannot push the numerator over uint256 before division.
        return Math.mulDiv(userScore, snapshotTotalBonus, globalScore);
    }

    /// @dev `UNDER_ATTACK` is intentionally NOT blocked while `PROMOTION_REQUESTED` is. Both are
    /// active-risk (attackable, still corruptible); the asymmetry is about deposit *timing*, not
    /// safety — UNDER_ATTACK deposits earn ~zero k=2 bonus and self-lock (no trap), whereas
    /// PROMOTION_REQUESTED is the closing-window stretch where a late join would be gameable. See
    /// docs/DESIGN.md (deposit gating).
    function _assertDepositsAllowed(IAttackRegistry.ContractState state) private pure {
        if (
            state == IAttackRegistry.ContractState.PROMOTION_REQUESTED
                || state == IAttackRegistry.ContractState.PRODUCTION || state == IAttackRegistry.ContractState.CORRUPTED
        ) {
            revert StakingClosed();
        }
    }

    /// @notice Resolves current agreement state through Safe Harbor Registry.
    /// @dev Read live every call; the registry is a trusted protocol-DAO singleton — its liveness
    /// and integrity are an explicit out-of-model trust assumption. See docs/DESIGN.md (external
    /// dependency).
    function _getAgreementState() internal view returns (IAttackRegistry.ContractState) {
        address attackRegistry = safeHarborRegistry.getAttackRegistry();
        if (attackRegistry == address(0)) revert InvalidAgreement();
        return IAttackRegistry(attackRegistry).getAgreementState(agreement);
    }

    /// @dev Replaces the pool's BattleChain scope wholesale. Validates each account against the
    /// agreement's `isContractInScope`. `accounts` must be non-empty. Used by both `initialize`
    /// and `setPoolScope`. Does NOT consult `scopeLocked` — callers gate that.
    function _replaceScope(address[] calldata accounts) internal {
        if (accounts.length == 0) revert EmptyScope();

        // Clear existing scope first so this is a wholesale replacement.
        address[] memory old = _scopeAccounts;
        // aderyn-fp-next-line(costly-loop) aderyn-fp-next-line(uninitialized-local-variable)
        for (uint256 i; i < old.length; ++i) {
            isAccountInScope[old[i]] = false;
        }
        delete _scopeAccounts;

        // Apply the new scope and validate against the agreement. The revert-on-invalid-account
        // is intentional: scope-setting must be atomic, so a single out-of-agreement account
        // rejects the whole call rather than being silently skipped.
        // aderyn-fp-next-line(costly-loop) aderyn-fp-next-line(require-revert-in-loop) aderyn-fp-next-line(uninitialized-local-variable)
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (isAccountInScope[account]) revert DuplicateAccount(account);
            // aderyn-fp-next-line(reentrancy-state-change)
            if (!IAgreement(agreement).isContractInScope(account)) {
                revert AccountNotInAgreementScope(account);
            }
            _scopeAccounts.push(account);
            isAccountInScope[account] = true;
        }

        emit ScopeUpdated(accounts);
    }

    /// @dev Lazily observes registry transitions: locks scope on first observation past the
    /// pre-attack states (NOT_DEPLOYED, NEW_DEPLOYMENT), opens the risk window on first
    /// active-risk observation (UNDER_ATTACK / PROMOTION_REQUESTED — not terminal states), and
    /// seals the risk window end on first terminal-state observation. All side effects are
    /// one-way and safe to call repeatedly. Reads registry state at most once per invocation
    /// and returns it so callers can avoid a second external lookup.
    function _observePoolState() internal returns (IAttackRegistry.ContractState state) {
        state = _getAgreementState();
        if (
            !scopeLocked && state != IAttackRegistry.ContractState.NOT_DEPLOYED
                && state != IAttackRegistry.ContractState.NEW_DEPLOYMENT
        ) {
            scopeLocked = true;
            emit ScopeLocked(block.timestamp);
        }
        if (riskWindowStart == 0 && _isActiveRiskState(state)) {
            _markRiskWindowStart();
        }
        if (riskWindowEnd == 0 && _isTerminalState(state)) {
            _markRiskWindowEnd();
        }
    }

    function _markRiskWindowStart() internal {
        // Cap at expiry: accrual is bounded by the pool's lifecycle. Without the cap, a late
        // observation could pin riskWindowStart > expiry, and `_clampUserSums` would record every
        // pre-risk deposit as entering past T = expiry (EXPIRED path). The k=2 sums then encode
        // post-deadline "at-risk" time that never actually existed.
        uint256 t = block.timestamp;
        if (t > expiry) t = expiry;
        // Cast is truncation-safe: `t` is capped at `expiry`, which is itself a uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        riskWindowStart = uint32(t);
        // Eagerly reset the global accumulators so every currently-eligible staker is treated as
        // entering at `t`. Per-user sums stay stale until `_clampUserSums` runs on the next op
        // touching that user.
        sumStakeTime = totalEligibleStake * t;
        sumStakeTimeSq = totalEligibleStake * t * t;
        emit RiskWindowStarted(t);
    }

    function _markRiskWindowEnd() internal {
        // Mirrors the cap in _markRiskWindowStart: accrual is bounded by the pool's lifecycle.
        // A post-expiry observation otherwise inflates T (= riskWindowEnd) and shifts bonus
        // share away from early stakers as the (T - entry)² ratio compresses toward 1.
        uint256 t = block.timestamp;
        if (t > expiry) t = expiry;
        // Cast is truncation-safe: `t` is capped at `expiry`, which is itself a uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        riskWindowEnd = uint32(t);
        emit RiskWindowEnded(t);
    }

    /// @dev Active-risk states only (UNDER_ATTACK, PROMOTION_REQUESTED). Terminal states do
    /// not count as risk observations — see the "no observable risk" rule.
    function _isActiveRiskState(IAttackRegistry.ContractState s) internal pure returns (bool) {
        return s == IAttackRegistry.ContractState.UNDER_ATTACK || s == IAttackRegistry.ContractState.PROMOTION_REQUESTED;
    }

    function _isTerminalState(IAttackRegistry.ContractState s) internal pure returns (bool) {
        return s == IAttackRegistry.ContractState.PRODUCTION || s == IAttackRegistry.ContractState.CORRUPTED;
    }
}
