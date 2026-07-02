// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";

contract ClaimExpiredRegistryGateTest is BaseConfidencePoolTest {
    function testClaimExpiredRevertsWhenAgreementCorruptedDuringModeratorGrace() external {
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.warp(pool.expiry());

        // Inside the grace window — only the moderator can resolve a CORRUPTED registry.
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.AgreementCorruptedAwaitingModerator.selector);
        pool.claimExpired();

        // One second before the boundary — still reverts (strict `<` comparison).
        vm.warp(pool.expiry() + pool.MODERATOR_CORRUPTED_GRACE() - 1);
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.AgreementCorruptedAwaitingModerator.selector);
        pool.claimExpired();
    }

    function testClaimExpiredAutoResolvesCorruptedAfterModeratorGrace() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        _contributeBonus(carol, 30 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.warp(pool.expiry() + pool.MODERATOR_CORRUPTED_GRACE());

        vm.expectEmit(true, false, false, true, address(pool));
        emit IConfidencePool.OutcomeFlagged(address(0), PoolStates.Outcome.CORRUPTED, false, address(0));

        // Permissionless caller — dave is not a staker, but the grace has elapsed so they can
        // finalize the outcome.
        vm.prank(dave);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.CORRUPTED));
        assertFalse(pool.goodFaith(), "bad-faith auto-resolve");
        assertEq(pool.attacker(), address(0), "no attacker named in mechanical resolution");
        assertEq(pool.snapshotTotalStaked(), 150 * ONE);
        assertEq(pool.snapshotTotalBonus(), 30 * ONE);
        assertEq(pool.corruptedReserve(), 180 * ONE, "full pool flagged for sweep");
        assertEq(pool.bountyEntitlement(), 0, "no bounty in bad-faith auto-resolve");

        // The caller (dave) receives nothing — bad-faith pays the recovery address.
        assertEq(token.balanceOf(dave), 0);
    }

    function testClaimCorruptedSweepsFullPoolAfterModeratorGraceAutoResolve() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        _contributeBonus(carol, 30 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.warp(pool.expiry() + pool.MODERATOR_CORRUPTED_GRACE());

        pool.claimExpired(); // triggers auto-CORRUPTED

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.claimCorrupted();
        // Stake + bonus all go to recovery.
        assertEq(token.balanceOf(recovery) - recoveryBefore, 180 * ONE);
        // Stakers get nothing: bad-faith CORRUPTED forfeits their position.
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function testModeratorCanStillResolveDuringGracePeriod() external {
        // Sanity check: the grace path is a backstop; it doesn't disable the moderator. While the
        // grace is active, the moderator can resolve as good-faith CORRUPTED naming the attacker.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 30 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.warp(pool.expiry() + pool.MODERATOR_CORRUPTED_GRACE() - 1 days);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.CORRUPTED));
        assertTrue(pool.goodFaith(), "moderator preserved good-faith path");
        assertEq(pool.attacker(), attacker);
        assertGt(pool.bountyEntitlement(), 0, "good-faith bounty exists");
    }

    function testClaimExpiredAutoResolvesToSurvivedWhenAgreementProduction() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        _contributeBonus(carol, 30 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.warp(pool.expiry());

        uint256 expectedPrincipal = 100 * ONE;
        uint256 expectedBonus = 20 * ONE;
        uint256 expectedPayout = expectedPrincipal + expectedBonus;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IConfidencePool.OutcomeFlagged(address(0), PoolStates.Outcome.SURVIVED, false, address(0));
        vm.expectEmit(true, false, false, true, address(pool));
        emit IConfidencePool.ClaimSurvived(alice, expectedPrincipal, expectedBonus);

        vm.prank(alice);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.SURVIVED));
        assertEq(pool.snapshotTotalStaked(), 150 * ONE);
        assertEq(pool.snapshotTotalBonus(), 30 * ONE);
        // outcomeFlaggedAt is `riskWindowEnd`, sealed when registry was set to PRODUCTION above.
        assertEq(token.balanceOf(alice) - aliceBefore, expectedPayout);
    }

    function testSubsequentCallersCanUseClaimSurvivedAfterProductionAutoResolve() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        _contributeBonus(carol, 30 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.warp(pool.expiry());

        vm.prank(alice);
        pool.claimExpired();

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();

        // No active-risk state ever observed → no bonus payout. Bob gets principal only.
        assertEq(token.balanceOf(bob) - bobBefore, 50 * ONE);
    }

    function testClaimExpiredStillWorksInPreTerminalRegistryState() external {
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 20 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);
        vm.warp(pool.expiry());

        uint256 aliceBefore = token.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IConfidencePool.OutcomeFlagged(address(0), PoolStates.Outcome.EXPIRED, false, address(0));
        vm.prank(alice);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED));
        assertEq(pool.snapshotTotalStaked(), 100 * ONE);
        assertEq(pool.snapshotTotalBonus(), 20 * ONE);
        assertEq(pool.outcomeFlaggedAt(), block.timestamp);
        // Pool expires without any active-risk observation → principal only, no bonus.
        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE);
    }

    function testModeratorCannotOverrideAutoCorrupted() external {
        // Regression: mechanical bad-faith CORRUPTED must be final. Without locking claimsStarted
        // here, the moderator could re-flag to good-faith CORRUPTED naming an attacker and
        // redirect the full pool (stake + bonus) to that address via claimAttackerBounty.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 30 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.warp(pool.expiry() + pool.MODERATOR_CORRUPTED_GRACE());

        vm.prank(dave);
        pool.claimExpired();

        assertTrue(pool.claimsStarted(), "auto-CORRUPTED locks the outcome");

        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);
    }

    function testModeratorCannotOverrideAutoSurvived() external {
        // Defense-in-depth: even though the registry state machine wouldn't allow a
        // PRODUCTION→CORRUPTED move that would unlock a moderator override here, locking on
        // mechanical resolution removes the dependency on that external invariant. Non-staker
        // caller so the auto-resolve early-returns at `userEligible == 0` and we exercise the
        // new lock, not the pre-existing one inside the payout path.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.warp(pool.expiry());

        vm.prank(dave);
        pool.claimExpired();

        assertTrue(pool.claimsStarted(), "auto-SURVIVED locks the outcome");

        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.OutcomeAlreadySet.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function testModeratorCannotOverrideAutoExpired() external {
        // EXPIRED is otherwise rejected by flagOutcome's outcome validation, but locking
        // claimsStarted makes the finality of mechanical resolution uniform across all branches.
        // Non-staker caller so the auto-resolve early-returns at `userEligible == 0`.
        _stake(alice, 100 * ONE);
        vm.warp(pool.expiry());

        vm.prank(dave);
        pool.claimExpired();

        assertTrue(pool.claimsStarted(), "auto-EXPIRED locks the outcome");
    }

    function testClaimExpiredDoesNotMutateRiskWindowPostResolution() external {
        // Regression: a post-resolution registry transition into active-risk must not flip
        // riskWindowStart — see the comment in claimExpired for the corruption mechanism.
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        _contributeBonus(carol, 30 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);
        vm.warp(pool.expiry());

        vm.prank(alice);
        pool.claimExpired();
        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED));
        assertEq(pool.riskWindowStart(), 0);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimExpired();

        assertEq(pool.riskWindowStart(), 0, "late claim must not flip riskWindowStart");
        assertEq(token.balanceOf(bob) - bobBefore, 50 * ONE);
    }

    function testPokeRiskWindowDoesNotMutateRiskWindowPostResolution() external {
        // Companion to the test above for the other post-resolution entry point: pokeRiskWindow
        // must be a no-op once resolved. A late risk-window seal would collapse every bonus share
        // to zero while flipping sweepUnclaimedBonus into reserving the bonus pool forever,
        // trapping it behind a single non-claiming staker.
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);
        _contributeBonus(carol, 100 * ONE);

        // Pool expires with the registry NEVER in an active-risk state. A non-staker resolves it
        // to EXPIRED with riskWindowStart == 0 — the bonus is now fully sweepable to recovery.
        vm.warp(pool.expiry());
        vm.prank(carol);
        pool.claimExpired();
        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED), "expired");
        assertEq(pool.riskWindowStart(), 0, "no observable risk at resolution");

        // Registry enters active-risk AFTER resolution; anyone pokes. The guard makes it a no-op.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        assertEq(pool.riskWindowStart(), 0, "poke must not seal riskWindowStart post-resolution");

        // Bob never claims, yet the full bonus pool still sweeps to recovery (not trapped).
        address recovery = pool.recoveryAddress();
        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedBonus();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 100 * ONE, "full bonus sweeps to recovery");

        // Both stakers' principal stays reserved and claimable.
        assertEq(pool.totalEligibleStake(), 200 * ONE, "both stakers' principal still reserved");
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimExpired();
        assertEq(token.balanceOf(bob) - bobBefore, 100 * ONE, "bob recovers his principal");
    }

    function testClaimExpiredWorksWhenRegistryUnavailablePostResolution() external {
        // Regression: once the outcome is set, claimExpired must not depend on registry liveness,
        // or a broken registry would permanently trap remaining EXPIRED claimers' principal.
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        vm.warp(pool.expiry());

        vm.prank(alice);
        pool.claimExpired();

        // Clearing the attackRegistry pointer makes subsequent `_getAgreementState` reads revert.
        safeHarborRegistry.setAttackRegistry(address(0));

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimExpired();
        assertEq(token.balanceOf(bob) - bobBefore, 50 * ONE);
    }

    function testClaimExpiredStillWorksForSecondCallerWhenAlreadyExpired() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 50 * ONE);
        _contributeBonus(carol, 30 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);
        vm.warp(pool.expiry());

        vm.prank(alice);
        pool.claimExpired();

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED));
        assertEq(pool.snapshotTotalStaked(), 150 * ONE);
        assertEq(pool.snapshotTotalBonus(), 30 * ONE);
        assertEq(pool.outcomeFlaggedAt(), block.timestamp);
        // No active-risk ever observed → principal only.
        assertEq(token.balanceOf(bob) - bobBefore, 50 * ONE);
    }
}
