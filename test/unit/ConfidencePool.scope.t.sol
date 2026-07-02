// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";

contract ConfidencePoolScopeTest is BaseConfidencePoolTest {
    address internal constant ACCOUNT_X = address(0xA1);
    address internal constant ACCOUNT_Y = address(0xA2);
    address internal constant ACCOUNT_Z = address(0xA3);

    function _seedAgreementScope() internal {
        agreementContract.setContractInScope(ACCOUNT_X, true);
        agreementContract.setContractInScope(ACCOUNT_Y, true);
        agreementContract.setContractInScope(ACCOUNT_Z, true);
    }

    function _multiAccountScope() internal pure returns (address[] memory accounts) {
        accounts = new address[](3);
        accounts[0] = ACCOUNT_X;
        accounts[1] = ACCOUNT_Y;
        accounts[2] = ACCOUNT_Z;
    }

    function testScopeSetAtInitializeIsReadable() external view {
        // The default scope from BaseConfidencePoolTest exposes one account.
        address[] memory accounts = pool.getScopeAccounts();
        assertEq(accounts.length, 1);
        assertEq(accounts[0], DEFAULT_SCOPE_ACCOUNT);

        assertTrue(pool.isAccountInScope(DEFAULT_SCOPE_ACCOUNT));
        assertFalse(pool.isAccountInScope(ACCOUNT_X));
        assertFalse(pool.scopeLocked());
    }

    function testSetPoolScopeReplacesPreviousScope() external {
        _seedAgreementScope();

        pool.setPoolScope(_multiAccountScope());

        address[] memory accounts = pool.getScopeAccounts();
        assertEq(accounts.length, 3);
        assertEq(accounts[0], ACCOUNT_X);
        assertEq(accounts[1], ACCOUNT_Y);
        assertEq(accounts[2], ACCOUNT_Z);

        assertTrue(pool.isAccountInScope(ACCOUNT_X));
        assertTrue(pool.isAccountInScope(ACCOUNT_Y));
        assertTrue(pool.isAccountInScope(ACCOUNT_Z));

        // The previous default scope must have been cleared.
        assertFalse(pool.isAccountInScope(DEFAULT_SCOPE_ACCOUNT));
    }

    function testSetPoolScopeRevertsWithEmptyScope() external {
        address[] memory empty = new address[](0);
        vm.expectRevert(IConfidencePool.EmptyScope.selector);
        pool.setPoolScope(empty);
    }

    function testSetPoolScopeRevertsOnDuplicateAccount() external {
        _seedAgreementScope();
        address[] memory accounts = new address[](3);
        accounts[0] = ACCOUNT_X;
        accounts[1] = ACCOUNT_Y;
        accounts[2] = ACCOUNT_X; // duplicate

        vm.expectRevert(abi.encodeWithSelector(IConfidencePool.DuplicateAccount.selector, ACCOUNT_X));
        pool.setPoolScope(accounts);
    }

    function testSetPoolScopeRevertsWhenAccountNotInAgreementScope() external {
        // ACCOUNT_X is NOT staged on the agreement (we only seed via _seedAgreementScope, which
        // is not called here). The default scope helper uses DEFAULT_SCOPE_ACCOUNT only.
        address[] memory accounts = new address[](1);
        accounts[0] = ACCOUNT_X;

        vm.expectRevert(abi.encodeWithSelector(IConfidencePool.AccountNotInAgreementScope.selector, ACCOUNT_X));
        pool.setPoolScope(accounts);
    }

    function testSetPoolScopeRevertsForNonOwner() external {
        _seedAgreementScope();
        vm.prank(alice);
        vm.expectRevert();
        pool.setPoolScope(_multiAccountScope());
    }

    function testScopeLocksOnFirstStakeAfterRegistryLeavesNewDeployment() external {
        // setUp leaves registry in NEW_DEPLOYMENT. Move it to ATTACK_REQUESTED, then any
        // gated interaction observes the new state and locks scope.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);

        assertFalse(pool.scopeLocked());

        _stake(alice, 100 * ONE);
        _withdraw(alice);

        assertTrue(pool.scopeLocked());
    }

    function testSetPoolScopeRevertsAfterLock() external {
        _seedAgreementScope();
        // Lock the scope by transitioning the registry and triggering a gated call.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);
        _stake(alice, 100 * ONE);
        _withdraw(alice);
        assertTrue(pool.scopeLocked());

        vm.expectRevert(IConfidencePool.ScopePostLockImmutable.selector);
        pool.setPoolScope(_multiAccountScope());
    }

    function testScopeLockedEventEmittedOnceAndNotAgain() external {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.ATTACK_REQUESTED);

        // First gated call flips the lock and emits ScopeLocked. Stage staker funds first so
        // the mint/approve transfer events don't interleave with the gated call we care about.
        token.mint(alice, 100 * ONE);
        vm.prank(alice);
        token.approve(address(pool), 100 * ONE);

        bytes32 scopeLockedTopic = keccak256("ScopeLocked(uint256)");

        vm.recordLogs();
        vm.prank(alice);
        pool.stake(100 * ONE);
        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        uint256 firstEmitCount = _countTopic(firstLogs, scopeLockedTopic, address(pool));
        assertEq(firstEmitCount, 1, "ScopeLocked should emit on first lock-triggering call");
        assertTrue(pool.scopeLocked());

        // Subsequent gated calls don't re-emit ScopeLocked.
        vm.recordLogs();
        _withdraw(alice);
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();
        uint256 secondEmitCount = _countTopic(secondLogs, scopeLockedTopic, address(pool));
        assertEq(secondEmitCount, 0, "ScopeLocked must not re-emit once already locked");
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic, address emitter) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count++;
            }
        }
    }

    function testScopeStaysUnlockedWhileRegistryRemainsNewDeployment() external {
        _seedAgreementScope();
        // Any number of pre-lock pool interactions while NEW_DEPLOYMENT must leave scope mutable.
        _stake(alice, 50 * ONE);
        _withdraw(alice);
        pool.setPoolScope(_multiAccountScope());

        assertFalse(pool.scopeLocked());
    }

    function testScopeStaysUnlockedWhileRegistryInNotDeployed() external {
        _seedAgreementScope();
        // NOT_DEPLOYED is the pre-deployment staging state — the pool should treat it the same
        // as NEW_DEPLOYMENT for scope-mutability purposes.
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NOT_DEPLOYED);
        _stake(alice, 50 * ONE);
        _withdraw(alice);
        pool.setPoolScope(_multiAccountScope());

        assertFalse(pool.scopeLocked());
    }

    function testModeratorCanFlagSurvivedWhenAgreementCorruptedOutOfScope() external {
        // The pool's scope is a binding subset of the agreement's. If the agreement is breached
        // but the vulnerability falls outside the pool's committed contracts, the moderator's
        // off-chain judgement is that this pool survived — stakers recover stake + bonus.
        _stake(alice, 100 * ONE);
        _contributeBonus(carol, 50 * ONE);
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);

        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        assertEq(uint256(pool.outcome()), uint256(PoolStates.Outcome.SURVIVED));

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.claimSurvived();
        assertEq(token.balanceOf(alice) - aliceBefore, 150 * ONE, "stake + full bonus");
    }

    function testFlagSurvivedStillRejectedFromNonTerminalRegistryStates() external {
        // Loosening the SURVIVED gate to accept CORRUPTED must not also permit flagging from
        // mid-attack registry states.
        _stake(alice, 100 * ONE);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);

        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidOutcome.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PROMOTION_REQUESTED);
        vm.prank(moderator);
        vm.expectRevert(IConfidencePool.InvalidOutcome.selector);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function testInitializeRevertsWithEmptyScope() external {
        ConfidencePool fresh = ConfidencePool(Clones.clone(address(new ConfidencePool())));
        address[] memory empty = new address[](0);
        vm.expectRevert(IConfidencePool.EmptyScope.selector);
        fresh.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            empty
        );
    }
}
