// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";
import {MockAttackRegistry} from "test/mocks/MockAttackRegistry.sol";

/// @notice Tests for the at-risk-only stake-seconds accrual and the pokeRiskWindow keeper hook.
contract ConfidencePoolRiskWindowTest is BaseConfidencePoolTest {
    function testRiskWindowStartZeroBeforeObservation() external view {
        assertEq(pool.riskWindowStart(), 0);
    }

    function testPokeRevertsInNewDeployment() external {
        vm.expectRevert(IConfidencePool.RiskWindowNotReached.selector);
        pool.pokeRiskWindow();
    }

    function testPokeRevertsInAttackRequested() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);
        vm.expectRevert(IConfidencePool.RiskWindowNotReached.selector);
        pool.pokeRiskWindow();
    }

    function testPokeSetsStartInUnderAttack() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IConfidencePool.RiskWindowStarted(vm.getBlockTimestamp());
        pool.pokeRiskWindow();

        assertEq(pool.riskWindowStart(), vm.getBlockTimestamp());
    }

    function testPokeSetsStartInPromotionRequested() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PROMOTION_REQUESTED);
        pool.pokeRiskWindow();
        assertEq(pool.riskWindowStart(), vm.getBlockTimestamp());
    }

    function testPokeInProductionWithoutPriorRiskDoesNotSealStart() external {
        // Registry jumps straight to PRODUCTION (no UNDER_ATTACK/PROMOTION_REQUESTED ever
        // observed). The pool's risk window never opens — riskWindowStart stays zero, and the
        // pool resolves as SURVIVED with no bonus payout (per the no-risk-no-reward rule).
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        pool.pokeRiskWindow();
        assertEq(pool.riskWindowStart(), 0, "no active-risk state was ever observed");
        assertEq(pool.riskWindowEnd(), vm.getBlockTimestamp(), "terminal observation still seals end");
    }

    function testPokeNoopWhenAlreadySet() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        uint256 firstStart = pool.riskWindowStart();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        pool.pokeRiskWindow();
        assertEq(pool.riskWindowStart(), firstStart, "poke must not move the start");
    }

    function testPokeAlsoLocksScope() external {
        assertFalse(pool.scopeLocked());
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);

        pool.pokeRiskWindow();

        assertTrue(pool.scopeLocked(), "poke triggers the merged state observation");
    }

    function testPokeAllowedWhilePaused() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pause();

        // Should not revert even though the pool is paused.
        pool.pokeRiskWindow();
        assertGt(pool.riskWindowStart(), 0);
    }

    function testContributeBonusSealsRiskWindowStart() external {
        // contributeBonus is a gated entrypoint; it must observe registry transitions like the
        // other gated entrypoints (stake, withdraw, etc.) so the risk window is sealed promptly
        // even if no one stakes/withdraws after the registry hits a risk state.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        assertEq(pool.riskWindowStart(), 0);

        _contributeBonus(carol, 10 * ONE);

        assertEq(pool.riskWindowStart(), vm.getBlockTimestamp());
    }

    function testPreRiskTimeEarnsNoBonusWhenRegistrySkipsActiveRisk() external {
        // alice sits in NEW_DEPLOYMENT, then registry jumps straight to PRODUCTION without ever
        // entering UNDER_ATTACK. No risk window was ever observed → stakers get principal only,
        // bonus stays unclaimed (eventually sweeps to recovery via sweepUnclaimedBonus).
        _stake(alice, 100 * ONE);
        vm.warp(vm.getBlockTimestamp() + 10 days);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE, "principal only, no bonus");
    }

    function testAtRiskTimeDrivesBonus() external {
        _stake(alice, 100 * ONE);

        // Open the at-risk window and let 5 days elapse inside it.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        vm.warp(vm.getBlockTimestamp() + 5 days);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        // alice is the only staker; she takes the full bonus regardless of dt > 0.
        assertEq(token.balanceOf(alice) - aliceBefore, 200 * ONE);
    }

    function testPreRiskTimeIgnoredForUserAccrual() external {
        // alice and bob stake pre-risk at different times. The pre-risk gap between their
        // entries must not give alice an edge in the bonus split — both are clamped to
        // riskWindowStart when the window opens.
        _stake(alice, 100 * ONE);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        _stake(bob, 100 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
        // 3 days at-risk together.
        vm.warp(vm.getBlockTimestamp() + 3 days);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();

        // Both effective entry times clamp to riskWindowStart; same stake, same dt → equal split.
        assertEq(token.balanceOf(alice) - aliceBefore, token.balanceOf(bob) - bobBefore);
    }

    function testUnobservedUnderAttackForfeitsRiskWindow() external {
        // alice stakes pre-risk. Registry transitions UNDER_ATTACK then PRODUCTION but nobody
        // pokes during UNDER_ATTACK, so `riskWindowStart` never seals. Stakers can't claim bonus
        // (no observable risk window) — but principal is preserved on SURVIVED.
        _stake(alice, 100 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        assertEq(pool.riskWindowStart(), 0, "still unobserved");

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // riskWindowStart stays zero because UNDER_ATTACK was never directly observed.
        assertEq(pool.riskWindowStart(), 0, "no active-risk state observation by flag time");
    }

    function testRiskWindowStartClampedAtExpiryWhenObservedLate() external {
        // Regression: if the registry is first observed in a risk state AFTER `expiry`,
        // riskWindowStart must be clamped to `expiry` rather than `block.timestamp`. The
        // EXPIRED auto-resolve path uses `T = expiry`; an unclamped post-expiry
        // riskWindowStart would push every user's effective entry above T and zero out all
        // bonus shares via the `effectiveEntry > T` early-exit in `_bonusShare`. Stakers would
        // receive stake back but no bonus, leaving the bonus pot stranded.
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);
        _contributeBonus(carol, 100 * ONE);

        uint256 expiryTs = pool.expiry();

        // Registry transitions to UNDER_ATTACK only AFTER the pool has expired. No one
        // observed the transition before expiry.
        vm.warp(expiryTs + 7 days);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);

        // First post-expiry call is claimExpired, which triggers the lazy observation.
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimExpired();
        uint256 alicePayout = token.balanceOf(alice) - aliceBefore;

        // riskWindowStart was sealed inside this call. It must be capped at expiry.
        assertEq(pool.riskWindowStart(), expiryTs, "riskWindowStart must be capped at expiry");

        // Alice was a 50% staker — she must receive her stake plus 50% of the bonus, not
        // be denied the bonus entirely.
        assertEq(alicePayout, 100 * ONE + 50 * ONE, "alice must receive her bonus share");

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimExpired();
        assertEq(token.balanceOf(bob) - bobBefore, 100 * ONE + 50 * ONE, "bob must receive his bonus share");
    }

    function testWithdrawRemainsDisabledAfterRegistryRewind() external {
        // Regression: withdraw gates on the pool's persisted `riskWindowStart` in addition
        // to the live registry state, so an upstream registry that rewinds to a pre-risk
        // state (registry replacement, mis-migration) cannot re-open withdrawals after the
        // pool has already observed a risk transition. The pool's own one-way flag is the
        // source of truth.
        _stake(alice, 100 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();

        // Upstream SafeHarborRegistry repoints `getAttackRegistry()` at a contract that
        // reports NEW_DEPLOYMENT for this agreement. Without the persisted-flag gate the
        // live state alone would re-enable withdraw.
        MockAttackRegistry rewound = new MockAttackRegistry();
        rewound.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);
        safeHarborRegistry.setAttackRegistry(address(rewound));

        assertGt(pool.riskWindowStart(), 0, "risk window stays sealed");

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();
    }

    function testTwoStakersOverlappingAtRiskTime() external {
        _stake(alice, 100 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();

        // alice alone in at-risk for 3 days.
        vm.warp(vm.getBlockTimestamp() + 3 days);

        // bob stakes mid-window — at-risk immediately (no maturation cliff).
        _stakeRaw(bob, 100 * ONE);

        // Both at-risk together for 1 day.
        vm.warp(vm.getBlockTimestamp() + 1 days);

        _contributeBonus(carol, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // alice: ~4 days of at-risk time. bob: ~1 day. alice should earn more bonus.
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        uint256 alicePayout = token.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();
        uint256 bobPayout = token.balanceOf(bob) - bobBefore;

        assertGt(alicePayout, bobPayout);
    }

    function testCorruptedFlagAllowedWhenRiskWindowNeverOpened() external {
        // A terminal CORRUPTED registry is sufficient for the moderator to flag CORRUPTED, even
        // if no pool interaction observed the active-risk interval (riskWindowStart stays zero).
        // The moderator's in-scope judgement is the source of truth for principal resolution.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        assertEq(pool.riskWindowStart(), 0);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.CORRUPTED));
    }

    function testCorruptedAutoResolveSkippedWhenRiskWindowNeverOpened() external {
        // Same scenario via the auto-resolution path: registry was never observed in an
        // active-risk state, so `claimExpired` post-grace falls through to EXPIRED instead of
        // auto-flagging bad-faith CORRUPTED. Stakers walk away with principal.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.warp(pool.expiry() + pool.MODERATOR_CORRUPTED_GRACE());

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimExpired();

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.EXPIRED));
        // Principal only; no bonus because no risk window was ever observed.
        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE);
    }
}
