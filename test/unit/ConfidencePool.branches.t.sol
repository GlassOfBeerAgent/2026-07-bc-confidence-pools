// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";
import {MockSafeHarborRegistry} from "test/mocks/MockSafeHarborRegistry.sol";

contract ConfidencePoolBranchesTest is BaseConfidencePoolTest {
    using stdStorage for StdStorage;

    function testRevert_initialize_zeroAgreement() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.ZeroAddress.selector);
        fresh.initialize(
            address(0),
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_zeroStakeToken() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.ZeroAddress.selector);
        fresh.initialize(
            agreement,
            address(0),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_zeroRegistry() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.ZeroAddress.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(0),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_zeroModerator() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.ZeroAddress.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            address(0),
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_zeroOwner() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.ZeroAddress.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(0),
            _defaultScope()
        );
    }

    function testRevert_initialize_zeroRecoveryAddress() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.InvalidRecoveryAddress.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            address(0),
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_expiryTooSoon() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.ExpiryTooSoon.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 29 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_zeroMinStake() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            0,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_invalidAgreement() external {
        ConfidencePool fresh = _newUninitializedPool();
        MockSafeHarborRegistry invalidRegistry = new MockSafeHarborRegistry();
        invalidRegistry.setAttackRegistry(address(attackRegistry));

        vm.expectRevert(IConfidencePool.InvalidAgreement.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(invalidRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_initialize_alreadyInitialized() external {
        vm.expectRevert();
        pool.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_stake_zeroAmount() external {
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        pool.stake(0);
    }

    function testRevert_stake_belowMinStake() external {
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.BelowMinStake.selector);
        pool.stake(ONE - 1);
        vm.stopPrank();
    }

    function testRevert_stake_outcomeAlreadySet() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.stake(ONE);
        vm.stopPrank();
    }

    function testRevert_stake_expired() external {
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.warp(pool.expiry());
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.stake(ONE);
        vm.stopPrank();
    }

    function testRevert_stake_promotionRequested() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PROMOTION_REQUESTED);
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.stake(ONE);
        vm.stopPrank();
    }

    function testRevert_stake_production() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.stake(ONE);
        vm.stopPrank();
    }

    function testRevert_stake_corrupted() external {
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.stake(ONE);
        vm.stopPrank();
    }

    function testRevert_contributeBonus_zeroAmount() external {
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        pool.contributeBonus(0);
    }

    function testRevert_contributeBonus_outcomeAlreadySet() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.contributeBonus(ONE);
        vm.stopPrank();
    }

    function testRevert_contributeBonus_expired() external {
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.warp(pool.expiry());
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.contributeBonus(ONE);
        vm.stopPrank();
    }

    function testRevert_contributeBonus_promotionRequested() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PROMOTION_REQUESTED);
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.contributeBonus(ONE);
        vm.stopPrank();
    }

    function testRevert_contributeBonus_production() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.contributeBonus(ONE);
        vm.stopPrank();
    }

    function testRevert_contributeBonus_corrupted() external {
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.StakingClosed.selector);
        pool.contributeBonus(ONE);
        vm.stopPrank();
    }

    function test_contributeBonus_succeedsInNewDeployment() external {
        token.mint(alice, ONE);
        vm.startPrank(alice);
        token.approve(address(pool), ONE);
        pool.contributeBonus(ONE);
        vm.stopPrank();

        assertEq(pool.totalBonus(), ONE);
    }

    function testRevert_withdraw_outcomeAlreadySet() external {
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.withdraw();
    }

    function testRevert_withdraw_noStake() external {
        // alice has no stake; withdraw reverts with InvalidAmount.
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        pool.withdraw();
    }

    function testRevert_withdraw_promotionRequested() external {
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PROMOTION_REQUESTED);

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();
    }

    function testRevert_withdraw_production() external {
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();
    }

    function testRevert_withdraw_corrupted() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();
    }

    function testRevert_withdraw_underAttack() external {
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();
    }

    function test_withdraw_succeedsInNewDeployment() external {
        _stake(alice, 10 * ONE);

        uint256 beforeBal = token.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw();
        assertEq(token.balanceOf(alice) - beforeBal, 10 * ONE);
    }

    function test_withdraw_succeedsInAttackRequested() external {
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);

        uint256 beforeBal = token.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw();
        assertEq(token.balanceOf(alice) - beforeBal, 10 * ONE);
    }

    function testRevert_flagOutcome_outcomeAlreadySetAfterClaim() external {
        // Re-flag is allowed pre-claim (typo recovery). Once any claim succeeds, the outcome
        // locks and re-flag reverts with OutcomeAlreadySet.
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.prank(alice);
        pool.claimSurvived();

        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function test_flagOutcome_canReflagBeforeAnyClaim() external {
        // Typo recovery: moderator flags SURVIVED but then realises the breach was in-scope.
        // Re-flagging to CORRUPTED is allowed while no claim has succeeded.
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.SURVIVED));
        assertFalse(pool.claimsStarted());

        // Override to CORRUPTED, bad-faith.
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.CORRUPTED));
        assertFalse(pool.goodFaith());
    }

    function test_flagOutcome_canReflagAttackerAddress() external {
        // Typo recovery on the attacker field: moderator named a wrong address, re-flags with
        // the correct one before the typo'd address claimed.
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        address wrongAttacker = makeAddr("typo");
        address rightAttacker = makeAddr("whitehat");

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, wrongAttacker);
        assertEq(pool.attacker(), wrongAttacker);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, rightAttacker);
        assertEq(pool.attacker(), rightAttacker);
    }

    function testRevert_flagOutcome_outcomeAlreadySetAfterAttackerClaim() external {
        // Once the good-faith attacker claims any bounty, the outcome locks.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.prank(attacker);
        pool.claimAttackerBounty();

        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function testRevert_flagOutcome_outcomeAlreadySetAfterClaimCorrupted() external {
        // claimCorrupted (bad-faith path) also locks the outcome.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        pool.claimCorrupted();

        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function testRevert_flagOutcome_outcomeAlreadySetAfterClaimExpiredPayout() external {
        // claimExpired's payout branch locks the outcome.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.warp(pool.expiry());

        vm.prank(alice);
        pool.claimExpired();

        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function test_sweepUnclaimedBonus_doesNotLockReflag() external {
        // Regression: a 1-wei donation post-flagOutcome must NOT let an attacker lock the
        // moderator's re-flag window via sweepUnclaimedBonus.
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // Trivial donation makes sweepUnclaimedBonus succeed for 1 wei.
        token.mint(address(pool), 1);
        pool.sweepUnclaimedBonus();
        assertFalse(pool.claimsStarted(), "sweep must not flip claimsStarted");

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.CORRUPTED));
    }

    function test_flagOutcome_reflagPreservesCorruptedClaimDeadline() external {
        // Re-flagging within good-faith CORRUPTED (e.g. fixing the attacker address) must NOT
        // extend `corruptedClaimDeadline` — otherwise the moderator could repeatedly re-flag to
        // indefinitely delay `sweepUnclaimedCorrupted`.
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        address rightAttacker = makeAddr("whitehat");

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);
        uint256 originalDeadline = pool.corruptedClaimDeadline();

        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, rightAttacker);

        assertEq(pool.corruptedClaimDeadline(), originalDeadline, "deadline preserved across gf re-flag");
        assertEq(pool.attacker(), rightAttacker, "attacker corrected");
    }

    function test_flagOutcome_firstGoodFaithCorruptedFromSurvivedSetsDeadline() external {
        // The first-ever transition INTO good-faith CORRUPTED sets the deadline, anchored to the
        // current block.timestamp (there is no earlier gf-CORRUPTED moment to anchor to).
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        assertEq(pool.corruptedClaimDeadline(), 0);

        uint256 flagTime = vm.getBlockTimestamp();
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        assertEq(pool.corruptedClaimDeadline(), flagTime + pool.CORRUPTED_CLAIM_WINDOW());
    }

    function test_flagOutcome_toggleThroughSurvivedCannotRefreshDeadline() external {
        // Regression: the moderator must not be able to mint a fresh attacker-claim window by
        // toggling gf-CORRUPTED -> SURVIVED -> gf-CORRUPTED. The deadline is anchored to the
        // first-ever gf-CORRUPTED flag and is monotonic across the round-trip.
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);
        uint256 originalDeadline = pool.corruptedClaimDeadline();

        // Detour out to SURVIVED (clears the live deadline) and back, well past the original flag.
        vm.warp(vm.getBlockTimestamp() + 90 days);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        assertEq(pool.corruptedClaimDeadline(), 0, "deadline cleared while not gf-CORRUPTED");

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        assertEq(pool.corruptedClaimDeadline(), originalDeadline, "deadline must not be refreshed by the detour");
    }

    function testRevert_flagOutcome_notModerator() external {
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.NotModerator.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function testRevert_flagOutcome_survivedWithGoodFaith() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidGoodFaithParams.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, true, address(0));
    }

    function testRevert_flagOutcome_survivedWithAttacker() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidGoodFaithParams.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, attacker);
    }

    function testRevert_flagOutcome_corruptedBadFaithWithAttacker() external {
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidGoodFaithParams.selector);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, attacker);
    }

    function testRevert_flagOutcome_corruptedGoodFaithZeroAttacker() external {
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidGoodFaithParams.selector);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, address(0));
    }

    function testRevert_flagOutcome_survivedWhenNotProduction() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidOutcome.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function testRevert_flagOutcome_corruptedWhenNotCorruptedState() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidOutcome.selector);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
    }

    function testRevert_flagOutcome_expiredOutcome() external {
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidOutcome.selector);
        pool.flagOutcome(PoolStates.Outcome.EXPIRED, false, address(0));
    }

    function testRevert_claimSurvived_unresolved() external {
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.OutcomeNotSet.selector);
        pool.claimSurvived();
    }

    function testRevert_claimSurvived_corrupted() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.OutcomeNotSet.selector);
        pool.claimSurvived();
    }

    function testRevert_claimSurvived_expired() external {
        _stake(alice, 10 * ONE);
        vm.warp(pool.expiry());
        vm.prank(alice);
        pool.claimExpired();

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.OutcomeNotSet.selector);
        pool.claimSurvived();
    }

    function testRevert_claimSurvived_doubleClaim() external {
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.prank(alice);
        pool.claimSurvived();
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        pool.claimSurvived();
    }

    function testRevert_claimSurvived_zeroBalance() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        pool.claimSurvived();
    }

    function testRevert_claimCorrupted_outcomeNotSet() external {
        vm.expectRevert(IConfidencePool.OutcomeNotSet.selector);
        pool.claimCorrupted();
    }

    function testRevert_claimCorrupted_nothingToSweep() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        pool.claimCorrupted();

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.claimCorrupted();
    }

    function testRevert_claimCorrupted_mustClaimBountyFirst() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.expectRevert(IConfidencePool.MustClaimBountyFirst.selector);
        pool.claimCorrupted();
    }

    function testRevert_claimCorrupted_nothingToSweepWithZeroBalance() external {
        // Force the pool balance to zero — bad-faith sweep has nothing to transfer.
        _stake(alice, 5 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        deal(address(token), address(pool), 0);

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.claimCorrupted();
    }

    function testRevert_claimAttackerBounty_outcomeNotSet() external {
        vm.prank(attacker);
        vm.expectRevert(IConfidencePool.OutcomeNotSet.selector);
        pool.claimAttackerBounty();
    }

    function testRevert_claimAttackerBounty_alreadyClaimed() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);
        vm.prank(attacker);
        pool.claimAttackerBounty();

        vm.prank(attacker);
        vm.expectRevert(IConfidencePool.BountyAlreadyClaimed.selector);
        pool.claimAttackerBounty();
    }

    function testRevert_claimAttackerBounty_badFaith() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        stdstore.target(address(pool)).sig("bountyEntitlement()").checked_write(uint256(1));

        vm.prank(attacker);
        vm.expectRevert(IConfidencePool.InvalidGoodFaithParams.selector);
        pool.claimAttackerBounty();
    }

    function testRevert_claimAttackerBounty_notAttacker() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.NotAttacker.selector);
        pool.claimAttackerBounty();
    }

    function testRevert_claimAttackerBounty_windowExpired() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.warp(pool.corruptedClaimDeadline() + 1);
        vm.prank(attacker);
        vm.expectRevert(IConfidencePool.ClaimWindowExpired.selector);
        pool.claimAttackerBounty();
    }

    function testRevert_sweepUnclaimed_outcomeNotSet() external {
        vm.expectRevert(IConfidencePool.OutcomeNotSet.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testRevert_sweepUnclaimed_notGoodFaith() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        vm.expectRevert(IConfidencePool.NotGoodFaithCorrupted.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testRevert_sweepUnclaimed_windowNotExpired() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.expectRevert(IConfidencePool.ClaimWindowNotExpired.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testSweepUnclaimedCorrupted_capsAtBalanceWhenUnderfunded() external {
        // Regression: balanceOf < corruptedReserve (sender-side fee on a prior outflow) must
        // partial-sweep, not revert.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.prank(address(pool));
        token.transfer(address(0xdead), 1);
        assertGt(pool.corruptedReserve(), token.balanceOf(address(pool)));

        vm.warp(pool.corruptedClaimDeadline() + 1);
        uint256 recoveryBefore = token.balanceOf(recovery);
        uint256 expectedSwept = token.balanceOf(address(pool));
        pool.sweepUnclaimedCorrupted();
        assertEq(token.balanceOf(recovery) - recoveryBefore, expectedSwept);
        assertEq(pool.corruptedReserve(), 0, "accounting cleared even when capped");
    }

    function testRevert_sweepUnclaimed_nothingToSweep() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);
        vm.warp(pool.corruptedClaimDeadline() + 1);
        pool.sweepUnclaimedCorrupted();

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testRevert_claimExpired_notExpired() external {
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.PoolNotExpired.selector);
        pool.claimExpired();
    }

    function testRevert_claimExpired_survivedOutcome() external {
        _stake(alice, 10 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        vm.warp(pool.expiry());

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidOutcome.selector);
        pool.claimExpired();
    }

    function testRevert_claimExpired_corruptedOutcome() external {
        _stake(alice, 10 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        vm.warp(pool.expiry());

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidOutcome.selector);
        pool.claimExpired();
    }

    function testRevert_claimExpired_doubleClaim() external {
        _stake(alice, 10 * ONE);
        vm.warp(pool.expiry());
        vm.prank(alice);
        pool.claimExpired();

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        pool.claimExpired();
    }

    function test_claimExpired_zeroBalanceFinalizesWithoutPayout() external {
        vm.warp(pool.expiry());
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED));
        assertEq(token.balanceOf(alice), balanceBefore);
        assertFalse(pool.hasClaimed(alice));
    }

    function testRevert_setRecoveryAddress_zeroAddress() external {
        vm.expectRevert(IConfidencePool.InvalidRecoveryAddress.selector);
        pool.setRecoveryAddress(address(0));
    }

    function testRevert_setRecoveryAddress_notOwner() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setRecoveryAddress(makeAddr("newRecovery"));
    }

    function testRevert_setExpiry_locked() external {
        _stake(alice, 10 * ONE);
        vm.expectRevert(IConfidencePool.ExpiryLocked.selector);
        pool.setExpiry(block.timestamp + 60 days);
    }

    function testRevert_setExpiry_tooSoon() external {
        vm.expectRevert(IConfidencePool.ExpiryTooSoon.selector);
        pool.setExpiry(block.timestamp + 1 days);
    }

    function testRevert_setExpiry_notOwner() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setExpiry(block.timestamp + 40 days);
    }

    function testRevert_pause_notOwner() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.pause();
    }

    function testRevert_unpause_notOwner() external {
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.unpause();
    }

    function testRevert_unpause_whenNotPaused() external {
        vm.expectRevert(IConfidencePool.PoolNotPaused.selector);
        pool.unpause();
    }

    function testRevert_pause_whenAlreadyPaused() external {
        pool.pause();
        vm.expectRevert(IConfidencePool.PoolPaused.selector);
        pool.pause();
    }

    function test_expiryLock_setOnFirstStake() external {
        assertEq(pool.expiryLocked(), false);
        _stake(alice, 10 * ONE);
        assertEq(pool.expiryLocked(), true);

        vm.expectRevert(IConfidencePool.ExpiryLocked.selector);
        pool.setExpiry(block.timestamp + 60 days);
    }

    /// @dev Timestamps are stored as uint32 (saturates 2106-02-07). These tests pin the cast at
    /// its boundary: an `expiry` set just below the ceiling must round-trip through the getter
    /// with no truncation. A bug computing the cast in a narrower domain, or an off-by-one in the
    /// width, would corrupt the stored value here even though the small-timestamp suite stays green.
    uint256 internal constant UINT32_MAX = type(uint32).max; // 4294967295 == 2106-02-07T06:28:15Z

    function test_initialize_nearUint32Ceiling_roundTripsExpiry() external {
        ConfidencePool fresh = _newUninitializedPool();
        // Warp near the ceiling, leave headroom for the +30 day lead requirement, and set expiry
        // a few seconds below the uint32 max.
        uint256 nearCeilingExpiry = UINT32_MAX - 7;
        vm.warp(nearCeilingExpiry - 31 days);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            nearCeilingExpiry,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
        assertEq(fresh.expiry(), nearCeilingExpiry, "expiry must survive the uint32 cast at the ceiling");
    }

    function test_setExpiry_nearUint32Ceiling_roundTrips() external {
        ConfidencePool fresh = _newUninitializedPool();
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
        uint256 nearCeilingExpiry = UINT32_MAX - 7;
        fresh.setExpiry(nearCeilingExpiry);
        assertEq(fresh.expiry(), nearCeilingExpiry, "setExpiry must survive the uint32 cast at the ceiling");
    }

    function testRevert_initialize_expiryAboveUint32Ceiling() external {
        ConfidencePool fresh = _newUninitializedPool();
        // Past the ceiling but still satisfies the +30 day lead check, so it isolates the
        // upper-bound guard rather than reverting ExpiryTooSoon.
        vm.warp(UINT32_MAX - 31 days);
        vm.expectRevert(IConfidencePool.ExpiryTooFar.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            UINT32_MAX + 1,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function testRevert_setExpiry_aboveUint32Ceiling() external {
        ConfidencePool fresh = _newUninitializedPool();
        vm.warp(UINT32_MAX - 31 days);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            UINT32_MAX,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
        vm.expectRevert(IConfidencePool.ExpiryTooFar.selector);
        fresh.setExpiry(UINT32_MAX + 1);
    }

    function _newUninitializedPool() internal returns (ConfidencePool fresh) {
        ConfidencePool implementation = new ConfidencePool();
        fresh = ConfidencePool(Clones.clone(address(implementation)));
    }
}
