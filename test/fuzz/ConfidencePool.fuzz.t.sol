// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";
import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {BaseConfidencePoolTest} from "test/helpers/BaseConfidencePoolTest.sol";

contract ConfidencePoolFuzzTest is BaseConfidencePoolTest {
    function testFuzz_stake_accountingInvariant(uint256[10] memory rawAmounts, address[10] memory rawUsers) external {
        uint256 expectedTotal;

        for (uint256 i; i < rawAmounts.length; ++i) {
            address user = _sanitizeUser(rawUsers[i], i);
            uint256 amount = bound(rawAmounts[i], pool.minStake(), 1e30);

            _stake(user, amount);
            expectedTotal += amount;
        }

        assertEq(pool.totalEligibleStake(), expectedTotal);
        assertGe(token.balanceOf(address(pool)), pool.totalEligibleStake() + pool.totalBonus());
    }

    function testFuzz_withdrawInNewDeployment(uint256 stakeAmtRaw) external {
        uint256 stakeAmt = bound(stakeAmtRaw, pool.minStake(), 1e30);
        _stake(alice, stakeAmt);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw();

        assertEq(token.balanceOf(alice) - aliceBefore, stakeAmt);
        assertEq(pool.eligibleStake(alice), 0);
    }

    function testFuzz_bonusContribution_neverRefundable(uint256 bonusRaw, address contributorSeed) external {
        address contributor = _sanitizeUser(contributorSeed, 999);
        uint256 bonus = bound(bonusRaw, 1, 1e30);
        uint256 beforeBonus = pool.totalBonus();

        _contributeBonus(contributor, bonus);
        assertEq(pool.totalBonus(), beforeBonus + bonus);

        _stake(alice, 10 * ONE);
        assertGe(pool.totalBonus(), beforeBonus + bonus);
    }

    function testFuzz_proRataPayout_sumsToPot(uint256[5] memory rawStakes) external {
        address[5] memory users = [alice, bob, carol, makeAddr("dave"), makeAddr("erin")];
        uint256 total;
        for (uint256 i; i < rawStakes.length; ++i) {
            uint256 amount = bound(rawStakes[i], pool.minStake(), 1e30);
            _stake(users[i], amount);
            total += amount;
        }

        _contributeBonus(makeAddr("bonus"), total / 2);

        // Pass through UNDER_ATTACK so the risk window opens; the bonus pays out per k=2.
        _passThroughUnderAttack();
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        vm.prank(moderator);
        pool.flagOutcome(PoolStates.Outcome.SURVIVED, false, address(0));

        uint256 snapshotGross = pool.snapshotTotalStaked() + pool.snapshotTotalBonus();
        uint256 claimed;
        for (uint256 i; i < users.length; ++i) {
            uint256 beforeBal = token.balanceOf(users[i]);
            vm.prank(users[i]);
            pool.claimSurvived();
            claimed += token.balanceOf(users[i]) - beforeBal;
        }

        uint256 dust = token.balanceOf(address(pool));
        assertLe(claimed, snapshotGross);
        assertLe(snapshotGross - claimed, users.length);
        assertEq(dust, snapshotGross - claimed);
    }

    function testFuzz_withdrawBlockedFromUnderAttackOnward(uint64 elapsedRaw) external {
        // Once the registry reaches UNDER_ATTACK or beyond, withdraw is permanently blocked.
        uint256 elapsed = bound(uint256(elapsedRaw), 0, 1000 days);

        _stake(alice, 100 * ONE);

        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        vm.warp(vm.getBlockTimestamp() + elapsed);

        vm.prank(alice);
        vm.expectRevert(IConfidencePool.WithdrawsDisabled.selector);
        pool.withdraw();
    }

    function _sanitizeUser(address user, uint256 salt) internal view returns (address) {
        if (user == address(0) || user == address(pool) || uint160(user) <= 9) {
            user = address(uint160(uint256(keccak256(abi.encode(user, salt, address(this))))));
        }
        if (user == alice || user == bob || user == carol || user == moderator || user == attacker || user == recovery)
        {
            user = address(uint160(uint256(keccak256(abi.encode(user, salt, "dedupe")))));
        }
        if (uint160(user) <= 9) {
            user = address(uint160(uint256(keccak256(abi.encode(user, salt, "precompile")))));
        }
        return user;
    }
}
