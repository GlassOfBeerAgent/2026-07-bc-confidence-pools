// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";

/// @notice Tests that the survivor bonus is distributed by stake-seconds (time-weighted),
/// not just by stake amount. Stakers who bore at-risk time for longer earn proportionally more.
contract ConfidencePoolTimeWeightedBonusTest is BaseConfidencePoolTest {
    function testEarlierStakerEarnsLargerBonusShareThanLaterStaker() external {
        _stake(alice, 100 * ONE);

        // Open the at-risk window. Only seconds accrued from here count toward bonus.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();

        // alice sits alone in the at-risk window for 7 days.
        vm.warp(vm.getBlockTimestamp() + 7 days);

        // bob stakes mid-attack — stake is at-risk immediately, no maturation cliff.
        _stake(bob, 100 * ONE);

        // bob sits alongside alice in the at-risk window for 1 day, then flag SURVIVED.
        vm.warp(vm.getBlockTimestamp() + 1 days);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        uint256 alicePayout = token.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();
        uint256 bobPayout = token.balanceOf(bob) - bobBefore;

        // alice bore 8 days of at-risk time, bob 1 day. Time-weighted bonus tilts toward alice.
        assertGt(alicePayout, bobPayout, "alice should earn more bonus than bob");
        // Sanity: principal + bonus should sum to ~200 (100 each principal) + 100 (bonus).
        assertApproxEqAbs(alicePayout + bobPayout, 300 * ONE, 10);
    }

    function testStakeSecondsFreezeAtFlagTimeNotClaimTime() external {
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        vm.warp(vm.getBlockTimestamp() + 1 days);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 aliceFlagPayout;
        {
            uint256 aliceBefore = token.balanceOf(alice);
            vm.prank(alice);
            pool.claimSurvived();
            aliceFlagPayout = token.balanceOf(alice) - aliceBefore;
        }

        // Reset and rerun, this time claiming much later. Stake-seconds must freeze at flag time.
        setUp();
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        vm.warp(vm.getBlockTimestamp() + 1 days);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // Wait a year before claiming.
        vm.warp(vm.getBlockTimestamp() + 365 days);

        uint256 aliceLatePayout;
        {
            uint256 aliceBefore = token.balanceOf(alice);
            vm.prank(alice);
            pool.claimSurvived();
            aliceLatePayout = token.balanceOf(alice) - aliceBefore;
        }

        assertEq(aliceFlagPayout, aliceLatePayout, "stake-seconds must freeze at flag time");
    }

    function testEqualStakersWithEqualStartsSplitBonusEqually() external {
        _stake(alice, 50 * ONE);
        _stake(bob, 50 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        vm.warp(vm.getBlockTimestamp() + 5 days);

        _contributeBonus(carol, 80 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        uint256 alicePayout = token.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();
        uint256 bobPayout = token.balanceOf(bob) - bobBefore;

        // 50 stake + 40 bonus each.
        assertEq(alicePayout, 90 * ONE);
        assertEq(bobPayout, 90 * ONE);
    }

    function testLastMinuteStakerEarnsMinimalBonus() external {
        // alice bears the full at-risk window.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // bob stakes just 1 second before flag.
        _stake(bob, 100 * ONE);
        vm.warp(vm.getBlockTimestamp() + 1);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        uint256 alicePayout = token.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();
        uint256 bobPayout = token.balanceOf(bob) - bobBefore;

        // bob gets ~100 stake back plus a sliver of bonus; alice takes nearly all the bonus.
        assertApproxEqAbs(bobPayout, 100 * ONE, ONE);
        assertApproxEqAbs(alicePayout, 200 * ONE, ONE);
    }

    function testBonusFallsBackToAmountWeightedWhenFlagSameBlockAsRiskWindow() external {
        // Regression: if at-risk time is zero (riskWindowStart == riskWindowEnd, observed in the
        // same block), the time-weighted formula yields globalScore == 0. _bonusShare falls back
        // to amount-weighted so the bonus still pays out.
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        _contributeBonus(carol, 60 * ONE);

        // Open and close the risk window in the same block.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        assertEq(pool.snapshotTotalStaked(), 150 * ONE);

        // Amount-weighted fallback: alice 100/150, bob 50/150 of 60 bonus.
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE + 40 * ONE);

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();
        assertEq(token.balanceOf(bob) - bobBefore, 50 * ONE + 20 * ONE);
    }
}
