// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {MockAgreement} from "test/mocks/MockAgreement.sol";
import {MockAttackRegistry} from "test/mocks/MockAttackRegistry.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "test/mocks/MockFeeOnTransferERC20.sol";
import {MockSafeHarborRegistry} from "test/mocks/MockSafeHarborRegistry.sol";

contract ConfidencePoolFeeOnTransferTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant MIN_STAKE = 100 * ONE;
    address internal constant SCOPE_ACCOUNT = address(0xC0FFEE);

    MockFeeOnTransferERC20 internal feeToken;
    MockAttackRegistry internal attackRegistry;
    MockSafeHarborRegistry internal safeHarborRegistry;
    MockAgreement internal agreementContract;
    ConfidencePool internal pool;

    address internal agreement;
    address internal moderator = makeAddr("moderator");
    address internal recovery = makeAddr("recovery");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        attackRegistry = new MockAttackRegistry();
        safeHarborRegistry = new MockSafeHarborRegistry();
        agreementContract = new MockAgreement(address(this));
        agreement = address(agreementContract);
        agreementContract.setContractInScope(SCOPE_ACCOUNT, true);
        safeHarborRegistry.setAttackRegistry(address(attackRegistry));
        safeHarborRegistry.setAgreementValid(agreement, true);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);

        feeToken = new MockFeeOnTransferERC20(100);
        pool = _deployPool(address(feeToken));
    }

    function testStakeWithFeeOnTransferCreditsReceivedAmount() external {
        uint256 amount = 200 * ONE;
        uint256 expectedReceived = amount - ((amount * feeToken.feeBps()) / 10_000);

        feeToken.mint(alice, amount);
        vm.startPrank(alice);
        feeToken.approve(address(pool), amount);
        pool.stake(amount);
        vm.stopPrank();

        assertEq(pool.eligibleStake(alice), expectedReceived);
        assertEq(pool.totalEligibleStake(), expectedReceived);
        assertEq(feeToken.balanceOf(address(pool)), expectedReceived);
    }

    function testContributeBonusWithFeeOnTransferCreditsReceivedAmount() external {
        uint256 amount = 200 * ONE;
        uint256 expectedReceived = amount - ((amount * feeToken.feeBps()) / 10_000);

        feeToken.mint(alice, amount);
        vm.startPrank(alice);
        feeToken.approve(address(pool), amount);
        pool.contributeBonus(amount);
        vm.stopPrank();

        assertEq(pool.totalBonus(), expectedReceived);
        assertEq(feeToken.balanceOf(address(pool)), expectedReceived);
    }

    function testTotalStakedMatchesBalanceAfterMultipleFoTStakes() external {
        _stake(alice, 200 * ONE);
        _stake(bob, 150 * ONE);
        _contributeBonus(carol, 50 * ONE);

        assertEq(pool.totalEligibleStake() + pool.totalBonus(), feeToken.balanceOf(address(pool)));
    }

    function testStakeRevertsNoTokensReceivedWith100PercentFee() external {
        feeToken.setFeeBps(10_000);

        feeToken.mint(alice, MIN_STAKE);
        vm.startPrank(alice);
        feeToken.approve(address(pool), MIN_STAKE);
        vm.expectRevert(IConfidencePool.NoTokensReceived.selector);
        pool.stake(MIN_STAKE);
        vm.stopPrank();
    }

    function testContributeBonusRevertsNoTokensReceivedWith100PercentFee() external {
        feeToken.setFeeBps(10_000);

        feeToken.mint(alice, ONE);
        vm.startPrank(alice);
        feeToken.approve(address(pool), ONE);
        vm.expectRevert(IConfidencePool.NoTokensReceived.selector);
        pool.contributeBonus(ONE);
        vm.stopPrank();
    }

    function testStakeWithStandardTokenCreditsExactAmount() external {
        MockERC20 standardToken = new MockERC20();
        ConfidencePool standardPool = _deployPool(address(standardToken));
        uint256 amount = 150 * ONE;

        standardToken.mint(alice, amount);
        vm.startPrank(alice);
        standardToken.approve(address(standardPool), amount);
        standardPool.stake(amount);
        vm.stopPrank();

        assertEq(standardPool.eligibleStake(alice), amount);
        assertEq(standardPool.totalEligibleStake(), amount);
        assertEq(standardToken.balanceOf(address(standardPool)), amount);
    }

    function testStakeFoTBelowMinStakePostFeeReverts() external {
        feeToken.mint(alice, MIN_STAKE);
        vm.startPrank(alice);
        feeToken.approve(address(pool), MIN_STAKE);
        vm.expectRevert(IConfidencePool.BelowMinStake.selector);
        pool.stake(MIN_STAKE);
        vm.stopPrank();
    }

    function _deployPool(address stakeToken) internal returns (ConfidencePool deployedPool) {
        ConfidencePool implementation = new ConfidencePool();
        deployedPool = ConfidencePool(Clones.clone(address(implementation)));
        address[] memory accounts = new address[](1);
        accounts[0] = SCOPE_ACCOUNT;
        deployedPool.initialize(
            agreement,
            stakeToken,
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            MIN_STAKE,
            recovery,
            address(this),
            accounts
        );
    }

    function _stake(address user, uint256 amount) internal {
        feeToken.mint(user, amount);
        vm.startPrank(user);
        feeToken.approve(address(pool), amount);
        pool.stake(amount);
        vm.stopPrank();
    }

    function _contributeBonus(address user, uint256 amount) internal {
        feeToken.mint(user, amount);
        vm.startPrank(user);
        feeToken.approve(address(pool), amount);
        pool.contributeBonus(amount);
        vm.stopPrank();
    }
}
