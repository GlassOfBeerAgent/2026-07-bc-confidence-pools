// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";

contract SweepUnclaimedBonusTest is BaseConfidencePoolTest {
    function testSweepUnclaimedBonusSurvivedHappyPath() external {
        _contributeBonus(carol, 40 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        assertEq(pool.snapshotTotalStaked(), 0);
        assertEq(pool.snapshotTotalBonus(), 40 * ONE);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IConfidencePool.BonusSwept(alice, recovery, 40 * ONE);

        uint256 recoveryBefore = token.balanceOf(recovery);
        vm.prank(alice);
        pool.sweepUnclaimedBonus();

        assertEq(token.balanceOf(recovery) - recoveryBefore, 40 * ONE);
        assertEq(token.balanceOf(address(pool)), 0);

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedBonus();
    }

    function testSweepUnclaimedBonusExpiredHappyPath() external {
        // alice withdraws (fully exits) before expiry so the snapshot has no stakers.
        _stake(alice, 10 * ONE);
        vm.prank(alice);
        pool.withdraw();
        _contributeBonus(carol, 30 * ONE);

        vm.warp(pool.expiry());
        vm.prank(alice);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED));
        assertEq(pool.snapshotTotalStaked(), 0);
        assertEq(pool.snapshotTotalBonus(), 30 * ONE);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IConfidencePool.BonusSwept(bob, recovery, 30 * ONE);

        uint256 recoveryBefore = token.balanceOf(recovery);
        vm.prank(bob);
        pool.sweepUnclaimedBonus();

        assertEq(token.balanceOf(recovery) - recoveryBefore, 30 * ONE);
        assertEq(token.balanceOf(address(pool)), 0);
    }

    function testRevertSweepUnclaimedBonusNothingExtraToSweep() external {
        // Pool holds exactly (principal + bonus) for the lone unclaimed staker; reserve covers
        // the full balance so the sweep has nothing to recover.
        _stake(alice, 10 * ONE);
        _contributeBonus(carol, 20 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedBonus();
    }

    function testRevertSweepUnclaimedBonusOutcomeNotEligibleForSweep() external {
        vm.expectRevert(IConfidencePool.OutcomeNotEligibleForSweep.selector);
        pool.sweepUnclaimedBonus();

        _stake(alice, 10 * ONE);
        _contributeBonus(carol, 20 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        vm.expectRevert(IConfidencePool.OutcomeNotEligibleForSweep.selector);
        pool.sweepUnclaimedBonus();
    }

    function testRevertSweepUnclaimedBonusNothingToSweep() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedBonus();
    }

    function testClaimExpiredFinalizesWhenAllStakersExited() external {
        _stake(alice, 10 * ONE);
        _contributeBonus(carol, 30 * ONE);
        vm.prank(alice);
        pool.withdraw();

        assertEq(pool.totalEligibleStake(), 0);

        vm.warp(pool.expiry());
        vm.prank(bob);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED));
        assertEq(pool.snapshotTotalStaked(), 0);
        assertEq(pool.snapshotTotalBonus(), 30 * ONE);

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedBonus();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 30 * ONE);
    }

    function testSweepRecoversResidueAfterAllStakersClaim() external {
        // Three stakers and a bonus that doesn't divide evenly. After all claim, integer
        // division leaves dust in the pool. The sweep should recover it.
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);
        _stake(carol, 100 * ONE);
        // 100 wei bonus → 33 wei each → 1 wei residue.
        _contributeBonus(dave, 100);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // Snapshot has stakers — under the old design, this would block sweeping forever.
        assertGt(pool.snapshotTotalStaked(), 0);

        vm.prank(alice);
        pool.claimSurvived();
        vm.prank(bob);
        pool.claimSurvived();
        vm.prank(carol);
        pool.claimSurvived();

        assertEq(pool.totalEligibleStake(), 0, "all stakers claimed");
        uint256 residue = token.balanceOf(address(pool));
        assertGt(residue, 0, "dust must remain after k=2 division");

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedBonus();

        assertEq(token.balanceOf(recovery) - recoveryBefore, residue, "sweep recovers exactly the dust");
        assertEq(token.balanceOf(address(pool)), 0, "pool fully drained");
    }

    function testSweepReservesOutstandingStakerEntitlements() external {
        // While stakers haven't all claimed, the reserve = principal + unclaimed bonus exactly
        // matches the pool balance, so no sweep is possible (NothingToSweep). After all
        // stakers claim, the residual dust becomes sweepable.
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);
        _contributeBonus(carol, 51); // odd bonus → dust after pro-rata

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedBonus();

        vm.prank(alice);
        pool.claimSurvived();
        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedBonus();

        vm.prank(bob);
        pool.claimSurvived();
        // After both claim, the dust (1 wei) is sweepable.
        pool.sweepUnclaimedBonus();
    }

    function testSweepRecoversDonationsAfterResolution() external {
        // No stakers, no bonus, but someone donates to the pool after resolution.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        token.mint(address(pool), 7 * ONE);

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedBonus();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 7 * ONE);
    }

    function testSweepRecoversDonationsWhileStakersStillUnclaimed() external {
        // Donations to the pool post-resolution are recoverable immediately, without waiting
        // for stakers to claim. Their principal + bonus entitlement stays reserved.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // Donation lands after resolution.
        token.mint(address(pool), 7 * ONE);

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedBonus();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 7 * ONE, "donation recovered immediately");

        // alice can still claim her full entitlement (100 stake + 50 bonus).
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        assertEq(token.balanceOf(alice) - aliceBefore, 150 * ONE, "alice unaffected by sweep");
    }

    function testSweepRecoversBonusWhenNoRiskWindowEverOpened() external {
        // Registry skips active-risk states entirely → riskWindowStart stays zero, so stakers
        // are owed zero bonus. The reserve should NOT lock the bonus pool against sweep just
        // because principal is still outstanding.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        assertEq(pool.riskWindowStart(), 0, "no active-risk ever observed");
        assertGt(pool.totalEligibleStake(), 0, "alice still unclaimed");

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedBonus();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 50 * ONE, "full bonus sweepable");

        // alice can still claim her principal afterward — sweep didn't touch the reserve.
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE, "principal preserved");
    }

    function testReflagToCorruptedAfterBonusSweepDoesNotOverstateEntitlement() external {
        // Regression: registry CORRUPTED, moderator flags SURVIVED (out-of-scope breach), the
        // unreserved bonus is swept, then the moderator re-flags good-faith CORRUPTED. The bounty
        // entitlement must reflect only funds still in the pool — not the already-swept bonus —
        // so claimAttackerBounty + claimCorrupted stay consistent and nothing bricks.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);

        // Registry CORRUPTED with no active-risk ever observed → riskWindowStart == 0.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        assertEq(pool.riskWindowStart(), 0, "no risk window observed");

        // Sweep the unreserved bonus (50) to recovery; principal (100) stays reserved.
        pool.sweepUnclaimedBonus();
        assertEq(token.balanceOf(address(pool)), 100 * ONE, "only principal remains");

        // Moderator changes their mind: re-flag good-faith CORRUPTED naming an attacker.
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        // Entitlement must be 100 (stake only) — the 50 bonus is gone and must not be counted.
        assertEq(pool.bountyEntitlement(), 100 * ONE, "entitlement excludes swept bonus");
        assertEq(pool.snapshotTotalBonus(), 0, "bonus dropped from snapshot after sweep");

        // Attacker claims the full (real) entitlement; bounty is then fully satisfied.
        vm.prank(attacker);
        pool.claimAttackerBounty();
        assertEq(pool.bountyClaimed(), pool.bountyEntitlement(), "bounty fully claimed");
        assertEq(token.balanceOf(attacker), 100 * ONE);

        // claimCorrupted is not blocked by a phantom shortfall (balance is 0, so NothingToSweep).
        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.claimCorrupted();
    }

    function testReflagToCorruptedAfterSweepThenDonationOnlyCountsLiveBonus() external {
        // After the bonus is swept (totalBonus -> 0), a fresh donation arrives, then the moderator
        // re-flags good-faith CORRUPTED. The donation is recoverable but must not inflate the
        // bounty entitlement, since it was never accounted bonus.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        pool.sweepUnclaimedBonus();

        // Stray donation lands after the sweep.
        token.mint(address(pool), 10 * ONE);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        // Entitlement is stake only; the donation is not bonus.
        assertEq(pool.bountyEntitlement(), 100 * ONE, "donation excluded from entitlement");

        // Attacker takes the 100 entitlement; the 10 donation remains and sweeps to recovery via
        // the CORRUPTED path.
        vm.prank(attacker);
        pool.claimAttackerBounty();
        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.claimCorrupted();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 10 * ONE, "donation recovered");
    }

    function testSweepDoesNotTouchTotalBonusWhenBonusReserved() external {
        // When the risk window opened, bonus is reserved for stakers and only donations sweep.
        // totalBonus must stay intact so stakers' bonus shares are unaffected.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);

        _passThroughUnderAttack(); // opens riskWindowStart
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        assertGt(pool.riskWindowStart(), 0, "risk window opened");

        uint256 bonusBefore = pool.totalBonus();

        // Donate, then sweep — only the donation should leave.
        token.mint(address(pool), 7 * ONE);
        pool.sweepUnclaimedBonus();

        assertEq(pool.totalBonus(), bonusBefore, "reserved bonus accounting untouched");

        // alice still claims her full principal + bonus.
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        assertEq(token.balanceOf(alice) - aliceBefore, 150 * ONE, "staker entitlement intact");
    }

    function testRevertSweepUnclaimedBonusNoDoubleSweep() external {
        _contributeBonus(carol, 15 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        pool.sweepUnclaimedBonus();

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedBonus();
    }
}
