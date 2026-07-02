// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {ConfidencePoolFactory} from "src/ConfidencePoolFactory.sol";
import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IConfidencePoolFactory} from "src/interfaces/IConfidencePoolFactory.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";
import {MockAgreement} from "test/mocks/MockAgreement.sol";
import {MockSafeHarborRegistry} from "test/mocks/MockSafeHarborRegistry.sol";

contract ConfidencePoolTest is BaseConfidencePoolTest {
    function testGoodFaithCorruptedFlow() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 30 * ONE);
        _stake(dave, 20 * ONE);
        _contributeBonus(carol, 40 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        // Eligible stake (150) + bonus (40) = 190 reserved for attacker.
        assertEq(pool.corruptedReserve(), 190 * ONE);

        uint256 attackerBefore = token.balanceOf(attacker);
        vm.prank(attacker);
        pool.claimAttackerBounty();
        assertEq(token.balanceOf(attacker) - attackerBefore, 190 * ONE);
        assertEq(pool.corruptedReserve(), 0);

        // Pool fully drained by the attacker; claimCorrupted reverts with nothing to sweep.
        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.claimCorrupted();
    }

    function testBadFaithCorruptedSweepForfeitsBountyAndBlocksResweep() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 30 * ONE);
        _contributeBonus(carol, 40 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        uint256 reserve = pool.corruptedReserve();
        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.claimCorrupted();
        assertEq(token.balanceOf(recovery) - recoveryBefore, reserve);
        assertEq(pool.bountyClaimed(), pool.bountyEntitlement());

        // Pool drained — repeat call reverts with NothingToSweep.
        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.claimCorrupted();
    }

    function testBadFaithCorruptedRecoversPostResolutionDonation() external {
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        pool.claimCorrupted(); // drains the protocol-tracked reserve

        // Donation arrives post-sweep.
        token.mint(address(pool), 7 * ONE);

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.claimCorrupted();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 7 * ONE, "donation swept to recovery");
    }

    function testWithdrawSucceedsInNotDeployed() external {
        // NOT_DEPLOYED is the pre-deployment staging state in the BattleChain registry — the
        // agreement exists but its protocol contracts haven't been deployed yet. The pool
        // treats this identically to NEW_DEPLOYMENT: stake, withdraw, and scope updates remain
        // open because no risk has materialised.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NOT_DEPLOYED);
        _stake(alice, 100 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        _withdraw(alice);

        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE);
        assertEq(pool.eligibleStake(alice), 0);
        // Scope must NOT lock during NOT_DEPLOYED — the agreement is still pre-attack.
        assertEq(pool.scopeLocked(), false, "NOT_DEPLOYED must not lock scope");
    }

    function testWithdrawSucceedsInNewDeployment() external {
        _stake(alice, 100 * ONE);

        uint256 aliceBefore = token.balanceOf(alice);
        _withdraw(alice);

        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE);
        assertEq(pool.eligibleStake(alice), 0);
    }

    function testWithdrawSucceedsInAttackRequested() external {
        // ATTACK_REQUESTED is the request to move the agreement into attackable mode; no attack
        // has happened yet. Withdrawals are still allowed here.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);

        uint256 aliceBefore = token.balanceOf(alice);
        _withdraw(alice);

        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE);
    }

    function testWithdrawRevertsOnceRegistryReachesUnderAttack() external {
        // UNDER_ATTACK is the first state where attack risk materialises; withdrawals are
        // permanently locked from this point until outcome is resolved.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();
    }

    function testStakerSweptOnCorruptedIfTheyMissTheExitWindow() external {
        // alice doesn't withdraw before UNDER_ATTACK. Her funds are in the snapshot and get
        // swept on CORRUPTED.
        _stake(alice, 100 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.claimCorrupted();
        assertEq(token.balanceOf(recovery) - recoveryBefore, 100 * ONE);
    }

    function testWithdrawForfeitsBonusClaim() external {
        // alice stakes, accrues stake-seconds, then exits during ATTACK_REQUESTED. She forfeits
        // her bonus claim — claimSurvived reverts because she has zero buckets at flag time.
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);

        vm.warp(vm.getBlockTimestamp() + 5 days);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);
        _withdraw(alice);

        // Pass through UNDER_ATTACK (poke) so the risk window opens and bob earns bonus.
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        // alice cannot claim bonus — both eligible and pending are zero.
        vm.prank(alice);
        vm.expectRevert(IConfidencePool.InvalidAmount.selector);
        pool.claimSurvived();

        // bob, who stayed, gets the entire bonus pool.
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        pool.claimSurvived();
        assertEq(token.balanceOf(bob) - bobBefore, 150 * ONE);
    }

    function testFactoryCreatePoolRequiresAgreementOwner() external {
        MockSafeHarborRegistry factoryRegistry = new MockSafeHarborRegistry();
        factoryRegistry.setAttackRegistry(address(attackRegistry));

        address agreementOwner = makeAddr("agreementOwner");
        MockAgreement mockAgreement = new MockAgreement(agreementOwner);
        factoryRegistry.setAgreementValid(address(mockAgreement), true);

        ConfidencePool implementation = new ConfidencePool();
        ConfidencePoolFactory factoryImpl = new ConfidencePoolFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                ConfidencePoolFactory.initialize, (address(factoryRegistry), address(implementation), moderator)
            )
        );
        ConfidencePoolFactory factory = ConfidencePoolFactory(address(proxy));
        factory.setStakeTokenAllowed(address(token), true);

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IConfidencePoolFactory.UnauthorizedCreator.selector);
        factory.createPool(
            address(mockAgreement), address(token), block.timestamp + 31 days, ONE, recovery, _defaultScope()
        );
    }

    function testFactoryCreatePoolWithEOAAgreementRevertsInvalidAgreement() external {
        MockSafeHarborRegistry factoryRegistry = new MockSafeHarborRegistry();
        factoryRegistry.setAttackRegistry(address(attackRegistry));

        ConfidencePool implementation = new ConfidencePool();
        ConfidencePoolFactory factoryImpl = new ConfidencePoolFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                ConfidencePoolFactory.initialize, (address(factoryRegistry), address(implementation), moderator)
            )
        );
        ConfidencePoolFactory factory = ConfidencePoolFactory(address(proxy));
        factory.setStakeTokenAllowed(address(token), true);

        vm.expectRevert(IConfidencePoolFactory.InvalidAgreement.selector);
        factory.createPool(
            makeAddr("eoaAgreement"), address(token), block.timestamp + 31 days, ONE, recovery, _defaultScope()
        );
    }

    function testBountyPlusSweepNeverExceedsSnapshotGross() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 30 * ONE);
        _stakeRaw(dave, 20 * ONE);
        _contributeBonus(carol, 40 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        uint256 gross = pool.snapshotTotalStaked() + pool.snapshotTotalBonus();
        deal(address(token), address(pool), 120 * ONE);

        vm.prank(attacker);
        pool.claimAttackerBounty();
        token.mint(address(pool), 70 * ONE);
        vm.prank(attacker);
        pool.claimAttackerBounty();

        uint256 attackerPaid = token.balanceOf(attacker);
        uint256 recoveryBefore = token.balanceOf(recovery);
        // claimCorrupted succeeds (sweeps remainder to recovery) when residual is positive, or
        // reverts NothingToSweep when the attacker drained everything. Other reverts must fail.
        try pool.claimCorrupted() {}
        catch (bytes memory reason) {
            assertEq(bytes4(reason), IConfidencePool.NothingToSweep.selector);
        }
        uint256 recoveryPaid = token.balanceOf(recovery) - recoveryBefore;

        assertLe(attackerPaid + recoveryPaid, gross);
    }

    function testBountyForfeitedAfterBadFaithSweep() external {
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 20 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        pool.claimCorrupted();

        vm.prank(attacker);
        vm.expectRevert(IConfidencePool.BountyAlreadyClaimed.selector);
        pool.claimAttackerBounty();
    }

    function testClaimAttackerBountySupportsPartialMultiClaimUntilEntitlement() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 30 * ONE);
        _stake(dave, 20 * ONE);
        _contributeBonus(carol, 40 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        // Drain to only 25 ONE so the bounty pays out partially. Total entitlement is 190.
        deal(address(token), address(pool), 25 * ONE);

        uint256 attackerBefore = token.balanceOf(attacker);
        vm.prank(attacker);
        pool.claimAttackerBounty();
        assertEq(token.balanceOf(attacker) - attackerBefore, 25 * ONE);
        assertEq(pool.bountyClaimed(), 25 * ONE);
        assertEq(pool.bountyEntitlement(), 190 * ONE);

        token.mint(address(pool), 30 * ONE);
        vm.prank(attacker);
        pool.claimAttackerBounty();
        assertEq(pool.bountyClaimed(), 55 * ONE);

        token.mint(address(pool), 135 * ONE);
        vm.prank(attacker);
        pool.claimAttackerBounty();
        assertEq(pool.bountyClaimed(), pool.bountyEntitlement());
        assertEq(pool.corruptedReserve(), 0);

        vm.prank(attacker);
        vm.expectRevert(IConfidencePool.BountyAlreadyClaimed.selector);
        pool.claimAttackerBounty();
    }

    function testClaimCorruptedGoodFaithRequiresBountyFirst() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 30 * ONE);
        _stake(dave, 20 * ONE);
        _contributeBonus(carol, 40 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        // Partial pool balance so the bounty can only pay partially at first.
        deal(address(token), address(pool), 10 * ONE);
        vm.prank(attacker);
        pool.claimAttackerBounty();

        vm.expectRevert(IConfidencePool.MustClaimBountyFirst.selector);
        pool.claimCorrupted();

        token.mint(address(pool), 180 * ONE);
        vm.prank(attacker);
        pool.claimAttackerBounty();

        // Attacker now fully claimed; pool drained, so claimCorrupted reverts NothingToSweep.
        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.claimCorrupted();
    }

    function testClaimAttackerBountyBeforeDeadlineSucceeds() external {
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 20 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.warp(pool.corruptedClaimDeadline());

        uint256 beforeBal = token.balanceOf(attacker);
        vm.prank(attacker);
        pool.claimAttackerBounty();

        assertEq(token.balanceOf(attacker) - beforeBal, pool.bountyEntitlement());
        assertEq(pool.bountyClaimed(), pool.bountyEntitlement());
    }

    function testClaimAttackerBountyAfterDeadlineReverts() external {
        _stake(alice, 100 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.warp(pool.corruptedClaimDeadline() + 1);
        vm.prank(attacker);
        vm.expectRevert(IConfidencePool.ClaimWindowExpired.selector);
        pool.claimAttackerBounty();
    }

    function testSweepUnclaimedCorruptedBeforeDeadlineReverts() external {
        _stake(alice, 100 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.expectRevert(IConfidencePool.ClaimWindowNotExpired.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testSweepUnclaimedCorruptedAfterDeadlineSucceeds() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 30 * ONE);
        _stakeRaw(dave, 20 * ONE);
        _contributeBonus(carol, 40 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        uint256 reserve = pool.corruptedReserve();
        uint256 recoveryBefore = token.balanceOf(recovery);

        vm.warp(pool.corruptedClaimDeadline() + 1);
        vm.expectEmit(true, true, false, true);
        emit IConfidencePool.UnclaimedCorruptedSwept(address(this), recovery, reserve);
        pool.sweepUnclaimedCorrupted();

        assertEq(token.balanceOf(recovery) - recoveryBefore, reserve);
        assertEq(pool.corruptedReserve(), 0);
        assertEq(pool.bountyClaimed(), pool.bountyEntitlement());
    }

    function testSweepUnclaimedCorruptedTwiceRevertsNothingToSweep() external {
        _stake(alice, 100 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        vm.warp(pool.corruptedClaimDeadline() + 1);
        pool.sweepUnclaimedCorrupted();

        vm.expectRevert(IConfidencePool.NothingToSweep.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testSweepUnclaimedCorruptedOnBadFaithReverts() external {
        _stake(alice, 100 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));

        vm.expectRevert(IConfidencePool.NotGoodFaithCorrupted.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testSweepUnclaimedCorruptedOnNonCorruptedOutcomeReverts() external {
        _stake(alice, 100 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        vm.expectRevert(IConfidencePool.OutcomeNotSet.selector);
        pool.sweepUnclaimedCorrupted();
    }

    function testPartialAttackerClaimThenDeadlineSweepTransfersResidual() external {
        _stake(alice, 100 * ONE);
        _stake(bob, 30 * ONE);
        _stake(dave, 20 * ONE);
        _contributeBonus(carol, 40 * ONE);

        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);

        // Drain to 25 ONE so the bounty pays partially.
        deal(address(token), address(pool), 25 * ONE);
        vm.prank(attacker);
        pool.claimAttackerBounty();
        assertEq(pool.bountyClaimed(), 25 * ONE);

        uint256 residual = pool.corruptedReserve();
        token.mint(address(pool), residual);

        vm.warp(pool.corruptedClaimDeadline() + 1);
        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedCorrupted();

        assertEq(token.balanceOf(recovery) - recoveryBefore, residual);
        assertEq(pool.corruptedReserve(), 0);
        assertEq(pool.bountyClaimed(), pool.bountyEntitlement());
    }

    function testCorruptedClaimDeadlineZeroForSurvivedExpiredAndBadFaith() external {
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        assertEq(pool.corruptedClaimDeadline(), 0);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);
        ConfidencePool survivedPool = _deployPool();
        token.mint(alice, 10 * ONE);
        vm.startPrank(alice);
        token.approve(address(survivedPool), 10 * ONE);
        survivedPool.stake(10 * ONE);
        vm.stopPrank();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        survivedPool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        assertEq(survivedPool.corruptedClaimDeadline(), 0);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);
        ConfidencePool expiredPool = _deployPool();
        token.mint(bob, 10 * ONE);
        vm.startPrank(bob);
        token.approve(address(expiredPool), 10 * ONE);
        expiredPool.stake(10 * ONE);
        vm.stopPrank();

        vm.warp(expiredPool.expiry());
        vm.prank(bob);
        expiredPool.claimExpired();
        assertEq(expiredPool.corruptedClaimDeadline(), 0);
    }

    // --- Pause scope tests ---

    function testStakeRevertsWhenPaused() external {
        token.mint(alice, 10 * ONE);
        vm.startPrank(alice);
        token.approve(address(pool), 10 * ONE);
        vm.stopPrank();

        pool.pause();

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.PoolPaused.selector);
        pool.stake(10 * ONE);
    }

    function testContributeBonusRevertsWhenPaused() external {
        token.mint(alice, 10 * ONE);
        vm.startPrank(alice);
        token.approve(address(pool), 10 * ONE);
        vm.stopPrank();

        pool.pause();

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.PoolPaused.selector);
        pool.contributeBonus(10 * ONE);
    }

    function testWithdrawSucceedsWhenPaused() external {
        // Withdraw is intentionally NOT pausable: the owner must never be able to trap stakers
        // in the pool. Pause covers inflows only (stake, contributeBonus).
        _stake(alice, 25 * ONE);
        pool.pause();

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw();
        assertEq(token.balanceOf(alice) - aliceBefore, 25 * ONE);
    }

    function testWithdrawSucceedsDuringPauseInAttackRequested() external {
        // Regression: previously the owner could pause during ATTACK_REQUESTED and wait for the
        // registry to move to UNDER_ATTACK, permanently locking stakers. Now stakers can exit
        // throughout the withdraw-eligible window regardless of pause state.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);
        pool.pause();

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw();
        assertEq(token.balanceOf(alice) - aliceBefore, 100 * ONE);
    }

    function testFlagOutcomeSucceedsWhenPaused() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        pool.pause();

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.SURVIVED));
    }

    function testClaimSurvivedSucceedsWhenPaused() external {
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
        pool.pause();

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();

        assertEq(token.balanceOf(alice) - balanceBefore, 100 * ONE);
    }

    function testClaimCorruptedSucceedsWhenPaused() external {
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, false, address(0));
        pool.pause();

        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.claimCorrupted();

        assertEq(token.balanceOf(recovery) - recoveryBefore, 100 * ONE);
    }

    function testClaimAttackerBountySucceedsWhenPaused() external {
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);
        pool.pause();

        uint256 balanceBefore = token.balanceOf(attacker);
        vm.prank(attacker);
        pool.claimAttackerBounty();

        assertEq(token.balanceOf(attacker) - balanceBefore, 100 * ONE);
    }

    function testSweepUnclaimedCorruptedSucceedsWhenPaused() external {
        _stake(alice, 100 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.CORRUPTED, true, attacker);
        pool.pause();

        vm.warp(pool.corruptedClaimDeadline() + 1);
        uint256 recoveryBefore = token.balanceOf(recovery);
        pool.sweepUnclaimedCorrupted();

        assertEq(token.balanceOf(recovery) - recoveryBefore, 100 * ONE);
    }

    function testClaimExpiredSucceedsWhenPaused() external {
        _stake(alice, 100 * ONE);
        pool.pause();

        vm.warp(pool.expiry());
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimExpired();

        assertEq(token.balanceOf(alice) - balanceBefore, 100 * ONE);
    }
}
