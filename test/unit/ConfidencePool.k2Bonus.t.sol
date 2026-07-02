// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfidencePool} from "src/ConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";

/// @notice Verifies the k=2 quadratic time-weighting of the bonus. Late entrants are crushed
/// (their bonus share scales with the square of elapsed at-risk time), while equal-time stakers
/// at any size split proportionally.
contract ConfidencePoolK2BonusTest is BaseConfidencePoolTest {
    function _flagSurvived() internal {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function _enterRisk() internal {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
    }

    function _claim(address user) internal returns (uint256 payout) {
        uint256 before = token.balanceOf(user);
        vm.prank(user);
        pool.claimSurvived();
        payout = token.balanceOf(user) - before;
    }

    function testQuadraticCrushesInsiderLastMinuteStaker() external {
        // Threat model from the design: a £50k insider who joins minutes before flag should
        // get vanishingly little bonus vs. a small but long-bearing staker.
        _stake(alice, 100 * ONE);

        _enterRisk();
        vm.warp(vm.getBlockTimestamp() + 21 days);

        _stake(bob, 50_000 * ONE);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);

        _contributeBonus(carol, 100 * ONE);
        _flagSurvived();

        uint256 aliceTotal = _claim(alice);
        uint256 bobTotal = _claim(bob);

        // alice's principal: 100 ONE. bob's: 50_000 ONE.
        uint256 aliceBonus = aliceTotal - 100 * ONE;
        uint256 bobBonus = bobTotal - 50_000 * ONE;

        // alice's bonus dominates because dt² × 100 ≫ (10min)² × 50000 with 21d vs 10min.
        // Concretely: alice score = 100 × (21d)² ≈ 100 × 3.29e12 = 3.29e14
        //             bob score = 50000 × (600)² = 50000 × 3.6e5 = 1.8e10
        // Ratio: ~99.99% to alice.
        assertGt(aliceBonus, bobBonus * 1000, "k=2 should crush the late-entry insider");
    }

    function testEqualTimeSplitsBonusProportionalToStake() external {
        // When dt is equal across stakers, k=2 reduces to amount-weighted (the (T - entry)²
        // factor cancels out of the share ratio). So a 10× whale should get ~10× the bonus.
        _stake(alice, 100 * ONE);
        _stake(bob, 1000 * ONE);

        _enterRisk();
        vm.warp(vm.getBlockTimestamp() + 7 days);

        _contributeBonus(carol, 110 * ONE);
        _flagSurvived();

        uint256 aliceBonus = _claim(alice) - 100 * ONE;
        uint256 bobBonus = _claim(bob) - 1000 * ONE;

        // Bob should get 10× alice's bonus (within integer dust).
        assertApproxEqRel(bobBonus, aliceBonus * 10, 0.001e18);
    }

    function testTopUpEarnsSameBonusAsAddressSplit() external {
        // Regression: top-up and split-address patterns with identical (amount, entry) deposits
        // must produce identical bonus. Under the old WA-blend the top-upper lost the Jensen gap.
        address bob2 = makeAddr("bob2");
        _enterRisk();
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);

        vm.warp(vm.getBlockTimestamp() + 10 days);
        _stake(alice, 100 * ONE); // top-up
        _stake(bob2, 100 * ONE); // address split

        vm.warp(vm.getBlockTimestamp() + 5 days);
        _contributeBonus(carol, 300 * ONE);
        _flagSurvived();

        uint256 aliceBonus = _claim(alice) - 200 * ONE;
        uint256 bobBonus = _claim(bob) - 100 * ONE;
        uint256 bob2Bonus = _claim(bob2) - 100 * ONE;
        // 1-wei tolerance: floor((x+y)·B/D) and floor(x·B/D)+floor(y·B/D) can differ by 1 due to
        // independent mulDiv rounding-down on each claim.
        assertApproxEqAbs(aliceBonus, bobBonus + bob2Bonus, 1, "top-up earns same bonus as split-address");
    }

    function testPerDepositSumsTrackedSeparately() external {
        // Storage-level check: per-user sums equal Σ per-deposit contributions, not the
        // blended-timestamp result.
        _enterRisk();
        uint256 t0 = vm.getBlockTimestamp();
        _stake(alice, 100 * ONE);
        vm.warp(t0 + 100);
        _stake(alice, 100 * ONE);

        uint256 expectedTime = 100 * ONE * t0 + 100 * ONE * (t0 + 100);
        uint256 expectedTimeSq = 100 * ONE * t0 * t0 + 100 * ONE * (t0 + 100) * (t0 + 100);
        assertEq(pool.userSumStakeTime(alice), expectedTime);
        assertEq(pool.userSumStakeTimeSq(alice), expectedTimeSq);
        assertEq(pool.sumStakeTime(), expectedTime);
        assertEq(pool.sumStakeTimeSq(), expectedTimeSq);
    }

    function testWithdrawZerosOutContribution() external {
        // alice and bob both stake at the same instant; alice withdraws pre-risk; bob takes
        // the entire bonus on SURVIVED (no dilution from alice's forfeited entry).
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);

        _withdraw(alice);

        _enterRisk();
        vm.warp(vm.getBlockTimestamp() + 5 days);

        _contributeBonus(carol, 100 * ONE);
        _flagSurvived();

        uint256 bobPayout = _claim(bob);
        // Bob gets his 100 principal + full 100 bonus = 200.
        assertEq(bobPayout, 200 * ONE);
    }

    function testEntryTimeClampedOnRiskWindowOpen() external {
        // alice stakes pre-risk at t=10s, bob 100s later, both at t=110s. Risk opens at
        // t=200s. Both effective entry times must be 200, regardless of stored entryTime[].
        uint256 t0 = vm.getBlockTimestamp();
        _stake(alice, 100 * ONE);
        vm.warp(t0 + 100);
        _stake(bob, 100 * ONE);
        vm.warp(t0 + 200);

        _enterRisk();
        uint256 windowStart = pool.riskWindowStart();
        assertEq(windowStart, t0 + 200);

        // Globals must reflect both stakers at entry = windowStart.
        assertEq(pool.sumStakeTime(), 200 * ONE * windowStart);
        assertEq(pool.sumStakeTimeSq(), 200 * ONE * windowStart * windowStart);

        // Per-user entryTime is still stale until next touch; verify by claiming both and
        // checking equal payouts (proves effective entry is clamped equally).
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _contributeBonus(carol, 100 * ONE);
        _flagSurvived();

        uint256 alicePayout = _claim(alice);
        uint256 bobPayout = _claim(bob);
        assertEq(alicePayout, bobPayout);
    }

    function testSameUserPreThenPostRiskDepositClampsFirstOnSecondStake() external {
        // Mixed-deposit composition for a single user: a pre-risk stake stores a stale entry
        // time at t0; when the user stakes again post-risk, `_clampUserSums` must promote the
        // first deposit's per-user sums to `riskWindowStart` BEFORE the second deposit accrues,
        // otherwise the post-risk top-up would be added on top of stale pre-risk values and the
        // user's score would diverge from the global accounting.
        uint256 t0 = vm.getBlockTimestamp();
        _stake(alice, 100 * ONE);

        // Open risk 100s after the first stake.
        vm.warp(t0 + 100);
        _enterRisk();
        uint256 windowStart = pool.riskWindowStart();
        assertEq(windowStart, t0 + 100);

        // Second stake 100s into the risk window. At the top of stake(), `_clampUserSums` should
        // promote alice's first deposit: stored sum was 100·ONE × t0, post-clamp must be
        // 100·ONE × windowStart. Then the new contribution at entry = t0+200 is added.
        vm.warp(t0 + 200);
        _stake(alice, 100 * ONE);

        uint256 expectedSumTime = 100 * ONE * windowStart + 100 * ONE * (t0 + 200);
        uint256 expectedSumTimeSq = 100 * ONE * windowStart * windowStart + 100 * ONE * (t0 + 200) * (t0 + 200);
        assertEq(pool.userSumStakeTime(alice), expectedSumTime, "first deposit promoted to windowStart");
        assertEq(pool.userSumStakeTimeSq(alice), expectedSumTimeSq, "first deposit sq promoted to windowStart");

        // End-to-end sanity: pay out and confirm alice (sole staker) walks with principal + full
        // bonus. The clamp must have left per-user and global sums consistent for this to hold.
        vm.warp(pool.expiry() - 1);
        _contributeBonus(carol, 50 * ONE);
        _flagSurvived();
        uint256 payout = _claim(alice);
        assertEq(payout, 250 * ONE, "sole staker takes principal + full bonus");
    }

    function testQuadraticHoldsAtUint32TimestampCeiling() external {
        // The bonus math reads `riskWindowStart` and `outcomeFlaggedAt` (both uint32) and computes
        // `T²·stake`. This test pins that arithmetic at the largest `T` the uint32 type permits
        // (just below the 2106 ceiling), where T² is maximal (~1.8e19) and any accidental
        // uint32-domain multiply would overflow-revert. Deploy a fresh pool near the ceiling so
        // riskWindowStart/outcomeFlaggedAt sit at the top of their range, then confirm the same
        // late-staker-crush relationship the small-timestamp tests assert still holds.
        uint256 nearCeilingExpiry = uint256(type(uint32).max) - 1;
        vm.warp(nearCeilingExpiry - 31 days);

        ConfidencePool ceilPool = _deployPool();
        // Replace `pool` so the shared _stake/_claim/_enterRisk helpers operate on the near-ceiling
        // pool for the remainder of this test.
        pool = ceilPool;

        _stake(alice, 100 * ONE);

        _enterRisk();
        vm.warp(vm.getBlockTimestamp() + 21 days);

        _stake(bob, 50_000 * ONE);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);

        _contributeBonus(carol, 100 * ONE);
        _flagSurvived();

        // Sanity: the markers really are up near the uint32 ceiling, not the small default base.
        assertGt(pool.riskWindowStart(), type(uint32).max - 32 days, "riskWindowStart near ceiling");
        assertGt(pool.outcomeFlaggedAt(), type(uint32).max - 32 days, "outcomeFlaggedAt near ceiling");

        uint256 aliceBonus = _claim(alice) - 100 * ONE;
        uint256 bobBonus = _claim(bob) - 50_000 * ONE;

        // Same invariant as testQuadraticCrushesInsiderLastMinuteStaker, but with T at the uint32
        // ceiling: the long-bearing small staker still crushes the last-minute whale, and neither
        // claim reverts on overflow.
        assertGt(aliceBonus, bobBonus * 1000, "k=2 crush must hold at the uint32 timestamp ceiling");
    }

    function testBonusShareDoesNotOverflowAtHighMagnitudes() external {
        // Pathological-but-tractable inputs that would overflow the naive
        // `userEligible * dt * dt * snapshotTotalBonus` multiplication chain (~1e80 vs the
        // uint256 ceiling ~1.16e77). With Math.mulDiv the final divide is done over 512-bit
        // intermediates, so this claim must succeed.
        uint256 huge = 1e34;
        _stake(alice, huge);

        _enterRisk();
        // Warp close to expiry so dt is at the realistic upper bound (~30 days).
        vm.warp(pool.expiry() - 1);

        _contributeBonus(carol, huge);
        _flagSurvived();

        // alice is the only staker, so she takes principal plus the full bonus.
        uint256 payout = _claim(alice);
        assertEq(payout, huge * 2);
    }
}
