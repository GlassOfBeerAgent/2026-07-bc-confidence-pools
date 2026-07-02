// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";

/// @notice Tests that the upper bound `T` used in the k=2 bonus score is pinned to the
/// earliest-observed terminal-registry-state timestamp (`riskWindowEnd`) for SURVIVED
/// resolutions, or to `expiry` for EXPIRED resolutions. The resolving call's own
/// `block.timestamp` must NOT affect bonus distribution.
contract ConfidencePoolRiskWindowEndTest is BaseConfidencePoolTest {
    function _enterRisk() internal {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
    }

    function testPokeSealsEndOnProduction() external {
        _enterRisk();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);

        uint256 t = vm.getBlockTimestamp();
        vm.expectEmit(true, false, false, true, address(pool));
        emit IConfidencePool.RiskWindowEnded(t);
        pool.pokeRiskWindow();

        assertEq(pool.riskWindowEnd(), t);
    }

    function testPokeSealsEndOnCorrupted() external {
        _enterRisk();
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        uint256 t = vm.getBlockTimestamp();
        pool.pokeRiskWindow();

        assertEq(pool.riskWindowEnd(), t);
    }

    function testPokeNoopWhenStartSetButRegistryStillInRisk() external {
        _enterRisk();
        uint256 startBefore = pool.riskWindowStart();

        // Registry still in UNDER_ATTACK; no terminal observation yet. Silent no-op.
        pool.pokeRiskWindow();

        assertEq(pool.riskWindowStart(), startBefore);
        assertEq(pool.riskWindowEnd(), 0);
    }

    function testPokeOnlySealsEndWhenRegistryJumpsToProduction() external {
        // Registry skips active-risk states entirely. riskWindowStart stays zero (no active-risk
        // ever observed) but riskWindowEnd seals because PRODUCTION is terminal.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        pool.pokeRiskWindow();

        assertEq(pool.riskWindowStart(), 0);
        assertEq(pool.riskWindowEnd(), vm.getBlockTimestamp());
    }

    function testPokeNoopOnceEndAlreadySealed() external {
        _enterRisk();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        pool.pokeRiskWindow();
        uint256 endBefore = pool.riskWindowEnd();

        vm.warp(vm.getBlockTimestamp() + 30 days);
        pool.pokeRiskWindow();

        assertEq(pool.riskWindowEnd(), endBefore, "end must not move once sealed");
    }

    function testFlagOutcomeUsesRiskWindowEndNotCallBlock() external {
        // riskWindowEnd is sealed promptly; moderator is slow to flag. outcomeFlaggedAt should
        // reflect the early observation, not the moderator's late call.
        _stake(alice, 100 * ONE);
        _enterRisk();

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        uint256 earlyEnd = vm.getBlockTimestamp();
        pool.pokeRiskWindow();
        assertEq(pool.riskWindowEnd(), earlyEnd);

        // DAO procrastinates for 30 days.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // outcomeFlaggedAt reflects the sealed end, not the moderator's call block.
        assertEq(pool.outcomeFlaggedAt(), earlyEnd);
    }

    function testClaimExpiredPRODUCTIONBranchUsesRiskWindowEnd() external {
        _stake(alice, 100 * ONE);
        _enterRisk();

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        uint256 earlyEnd = vm.getBlockTimestamp();
        pool.pokeRiskWindow();

        vm.warp(pool.expiry() + 10 days);
        vm.prank(alice);
        pool.claimExpired();

        assertEq(pool.outcomeFlaggedAt(), earlyEnd);
    }

    function testClaimExpiredEXPIREDBranchUsesExpiry() external {
        // Registry is still in NEW_DEPLOYMENT (or ATTACK_REQUESTED) at expiry. The pool's
        // terminal moment is its own deadline, not the resolving-call block.
        _stake(alice, 100 * ONE);

        uint256 expiry = pool.expiry();
        vm.warp(expiry + 5 days);
        vm.prank(alice);
        pool.claimExpired();

        assertEq(pool.outcomeFlaggedAt(), expiry);
    }

    function testGriefShiftRemovedForClaimExpired() external {
        // Headline test: with riskWindowEnd pinned, two stakers' bonus distribution is
        // identical whether the resolving call fires immediately or 30 days late.

        // Setup A: prompt resolve.
        _stake(alice, 100 * ONE);
        _enterRisk();
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _stake(bob, 100 * ONE);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        pool.pokeRiskWindow();
        vm.warp(pool.expiry());
        vm.prank(alice);
        pool.claimExpired();
        uint256 aliceA = token.balanceOf(alice) - 0;
        vm.prank(bob);
        pool.claimSurvived();
        uint256 bobA = token.balanceOf(bob) - 0;

        // Setup B: identical pre-PRODUCTION trajectory, but resolver waits an extra 30 days.
        setUp();
        _stake(alice, 100 * ONE);
        _enterRisk();
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _stake(bob, 100 * ONE);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        pool.pokeRiskWindow();
        // Resolver waits an extra 30 days beyond expiry.
        vm.warp(pool.expiry() + 30 days);
        vm.prank(alice);
        pool.claimExpired();
        uint256 aliceB = token.balanceOf(alice) - 0;
        vm.prank(bob);
        pool.claimSurvived();
        uint256 bobB = token.balanceOf(bob) - 0;

        assertEq(aliceA, aliceB, "alice's payout must not depend on resolve time");
        assertEq(bobA, bobB, "bob's payout must not depend on resolve time");
    }

    function testRiskWindowEndClampedAtExpiryWhenObservedLate() external {
        // Regression: terminal observation past expiry must clamp riskWindowEnd to expiry,
        // mirroring riskWindowStart's cap. Without the cap, T inflates with observation delay
        // and (T - entry)² ratios compress toward 1, shifting share to late stakers.
        _stake(alice, 100 * ONE);
        _enterRisk();

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);

        uint256 expiryTs = pool.expiry();
        vm.warp(expiryTs + 30 days);

        pool.pokeRiskWindow();
        assertEq(pool.riskWindowEnd(), expiryTs, "riskWindowEnd must clamp at expiry");
    }

    function testLazyEndObservationStillWorksAtFlagOutcomeTime() external {
        // Edge case: nobody pokes; the resolving call itself is the first to observe
        // PRODUCTION. riskWindowEnd is set inside _observePoolState during flagOutcome, and
        // then outcomeFlaggedAt picks up that just-set value.
        _stake(alice, 100 * ONE);
        _enterRisk();

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        // No poke; jump time forward.
        vm.warp(vm.getBlockTimestamp() + 10 days);
        assertEq(pool.riskWindowEnd(), 0, "end still unobserved");

        uint256 callBlock = vm.getBlockTimestamp();
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // Both the lazy end and outcomeFlaggedAt land at the call block (worst case).
        assertEq(pool.riskWindowEnd(), callBlock);
        assertEq(pool.outcomeFlaggedAt(), callBlock);
    }
}
