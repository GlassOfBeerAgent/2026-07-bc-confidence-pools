// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {ConfidencePoolFactory} from "src/ConfidencePoolFactory.sol";
import {IConfidencePoolFactory} from "src/interfaces/IConfidencePoolFactory.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAgreement} from "test/mocks/MockAgreement.sol";
import {MockConfidencePoolFactoryV2} from "test/mocks/MockConfidencePoolFactoryV2.sol";
import {MockSafeHarborRegistry} from "test/mocks/MockSafeHarborRegistry.sol";

contract ConfidencePoolFactoryTest is Test {
    bytes4 internal constant ENFORCED_PAUSE_SELECTOR = bytes4(keccak256("EnforcedPause()"));
    uint256 internal constant ONE = 1e18;
    address internal constant SCOPE_ACCOUNT = address(0xC0FFEE);

    MockERC20 internal token;
    MockSafeHarborRegistry internal registry;
    ConfidencePool internal poolImplementation;
    ConfidencePoolFactory internal factory;
    MockAgreement internal agreement;

    address internal agreementOwner = makeAddr("agreementOwner");
    address internal defaultModerator = makeAddr("defaultModerator");
    address internal recovery = makeAddr("recovery");

    function setUp() public {
        token = new MockERC20();
        registry = new MockSafeHarborRegistry();
        poolImplementation = new ConfidencePool();
        agreement = new MockAgreement(agreementOwner);
        agreement.setContractInScope(SCOPE_ACCOUNT, true);
        registry.setAgreementValid(address(agreement), true);

        ConfidencePoolFactory impl = new ConfidencePoolFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ConfidencePoolFactory.initialize, (address(registry), address(poolImplementation), defaultModerator)
            )
        );
        factory = ConfidencePoolFactory(address(proxy));
        factory.setStakeTokenAllowed(address(token), true);
    }

    function _scope() internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = SCOPE_ACCOUNT;
    }

    function test_createPool_success() external {
        uint256 expiry = block.timestamp + 31 days;
        bytes32 salt = keccak256(abi.encode(address(agreement), uint256(0)));
        address expectedPool = Clones.predictDeterministicAddress(address(poolImplementation), salt, address(factory));

        vm.expectEmit(true, true, false, true);
        emit IConfidencePoolFactory.PoolCreated(
            address(agreement), expectedPool, address(token), expiry, ONE, recovery, defaultModerator, address(registry)
        );

        vm.prank(agreementOwner);
        address created = factory.createPool(address(agreement), address(token), expiry, ONE, recovery, _scope());

        assertEq(created, expectedPool);
        address[] memory poolList = factory.getPoolsByAgreement(address(agreement));
        assertEq(poolList.length, 1);
        assertEq(poolList[0], created);
        assertEq(factory.poolCountByAgreement(address(agreement)), 1);
    }

    function test_createPool_assignsOwnerToAgreementOwnerAtomically() external {
        // Regression: ownership lands on the agreement owner inside `createPool`, with no
        // `owner() == factory` interim window and no `pendingOwner` left to accept.
        uint256 expiry = block.timestamp + 31 days;

        vm.prank(agreementOwner);
        address created = factory.createPool(address(agreement), address(token), expiry, ONE, recovery, _scope());

        assertEq(ConfidencePool(created).owner(), agreementOwner);
        assertEq(ConfidencePool(created).pendingOwner(), address(0));
    }

    function test_createPool_usesDefaultModerator() external {
        uint256 expiry = block.timestamp + 31 days;

        vm.prank(agreementOwner);
        address created = factory.createPool(address(agreement), address(token), expiry, ONE, recovery, _scope());

        assertEq(ConfidencePool(created).outcomeModerator(), defaultModerator);
    }

    function test_createPool_deterministicAddress() external {
        uint256 expiry = block.timestamp + 31 days;
        bytes32 salt = keccak256(abi.encode(address(agreement), uint256(0)));
        address expectedPool = Clones.predictDeterministicAddress(address(poolImplementation), salt, address(factory));

        vm.prank(agreementOwner);
        address created = factory.createPool(address(agreement), address(token), expiry, ONE, recovery, _scope());

        assertEq(created, expectedPool);
    }

    function testRevert_createPool_zeroAgreement() external {
        vm.prank(agreementOwner);
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        factory.createPool(address(0), address(token), block.timestamp + 31 days, ONE, recovery, _scope());
    }

    function testRevert_createPool_zeroStakeToken() external {
        vm.prank(agreementOwner);
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        factory.createPool(address(agreement), address(0), block.timestamp + 31 days, ONE, recovery, _scope());
    }

    function testRevert_createPool_zeroRecoveryAddress() external {
        vm.prank(agreementOwner);
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        factory.createPool(address(agreement), address(token), block.timestamp + 31 days, ONE, address(0), _scope());
    }

    function testRevert_createPool_invalidAgreement() external {
        MockAgreement invalidAgreement = new MockAgreement(agreementOwner);
        vm.prank(agreementOwner);
        vm.expectRevert(IConfidencePoolFactory.InvalidAgreement.selector);
        factory.createPool(
            address(invalidAgreement), address(token), block.timestamp + 31 days, ONE, recovery, _scope()
        );
    }

    function testRevert_createPool_unauthorizedCreator() external {
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IConfidencePoolFactory.UnauthorizedCreator.selector);
        factory.createPool(address(agreement), address(token), block.timestamp + 31 days, ONE, recovery, _scope());
    }

    function test_createPool_manyPoolsPerAgreement() external {
        uint256 expiry = block.timestamp + 31 days;

        vm.startPrank(agreementOwner);
        address first = factory.createPool(address(agreement), address(token), expiry, ONE, recovery, _scope());
        address second =
            factory.createPool(address(agreement), address(token), expiry + 1 days, ONE, recovery, _scope());
        address third = factory.createPool(address(agreement), address(token), expiry + 2 days, ONE, recovery, _scope());
        vm.stopPrank();

        // Distinct deterministic clone addresses thanks to the per-agreement index in the salt.
        assertTrue(first != second && second != third && first != third);

        address[] memory poolList = factory.getPoolsByAgreement(address(agreement));
        assertEq(poolList.length, 3);
        assertEq(poolList[0], first);
        assertEq(poolList[1], second);
        assertEq(poolList[2], third);
        assertEq(factory.poolCountByAgreement(address(agreement)), 3);

        // Second pool's address matches the index-1 deterministic prediction.
        bytes32 saltOne = keccak256(abi.encode(address(agreement), uint256(1)));
        assertEq(second, Clones.predictDeterministicAddress(address(poolImplementation), saltOne, address(factory)));
    }

    function testRevert_createPool_expiryTooSoon() external {
        vm.prank(agreementOwner);
        vm.expectRevert(IConfidencePoolFactory.ExpiryTooSoon.selector);
        factory.createPool(address(agreement), address(token), block.timestamp + 29 days, ONE, recovery, _scope());
    }

    function testRevert_createPool_whenPaused() external {
        factory.pause();

        vm.prank(agreementOwner);
        vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
        factory.createPool(address(agreement), address(token), block.timestamp + 31 days, ONE, recovery, _scope());

        factory.unpause();

        vm.prank(agreementOwner);
        address created =
            factory.createPool(address(agreement), address(token), block.timestamp + 31 days, ONE, recovery, _scope());
        assertTrue(created != address(0));
    }

    function test_setSafeHarborRegistry_success() external {
        MockSafeHarborRegistry newRegistry = new MockSafeHarborRegistry();
        vm.expectEmit(true, true, false, true);
        emit IConfidencePoolFactory.SafeHarborRegistryUpdated(address(registry), address(newRegistry));

        factory.setSafeHarborRegistry(address(newRegistry));
        assertEq(address(factory.safeHarborRegistry()), address(newRegistry));
    }

    function testRevert_setSafeHarborRegistry_zero() external {
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        factory.setSafeHarborRegistry(address(0));
    }

    function testRevert_setSafeHarborRegistry_notOwner() external {
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.setSafeHarborRegistry(makeAddr("newRegistry"));
    }

    function test_setStakeTokenAllowed_success() external {
        MockERC20 other = new MockERC20();
        assertFalse(factory.allowedStakeToken(address(other)));

        vm.expectEmit(true, false, false, true);
        emit IConfidencePoolFactory.StakeTokenAllowedUpdated(address(other), true);
        factory.setStakeTokenAllowed(address(other), true);
        assertTrue(factory.allowedStakeToken(address(other)));

        factory.setStakeTokenAllowed(address(other), false);
        assertFalse(factory.allowedStakeToken(address(other)));
    }

    function testRevert_setStakeTokenAllowed_zero() external {
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        factory.setStakeTokenAllowed(address(0), true);
    }

    function testRevert_setStakeTokenAllowed_notOwner() external {
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.setStakeTokenAllowed(makeAddr("tok"), true);
    }

    function testRevert_createPool_stakeTokenNotAllowed() external {
        MockERC20 other = new MockERC20();
        vm.prank(agreementOwner);
        vm.expectRevert(IConfidencePoolFactory.StakeTokenNotAllowed.selector);
        factory.createPool(address(agreement), address(other), block.timestamp + 31 days, ONE, recovery, _scope());
    }

    function test_createPool_succeedsAfterTokenAllowed() external {
        MockERC20 other = new MockERC20();
        factory.setStakeTokenAllowed(address(other), true);

        vm.prank(agreementOwner);
        address created =
            factory.createPool(address(agreement), address(other), block.timestamp + 31 days, ONE, recovery, _scope());
        assertTrue(created != address(0));
    }

    function test_delistingTokenDoesNotAffectExistingPools() external {
        vm.prank(agreementOwner);
        address created =
            factory.createPool(address(agreement), address(token), block.timestamp + 31 days, ONE, recovery, _scope());

        // De-list the token; the already-created pool still exists and keeps its stake token.
        factory.setStakeTokenAllowed(address(token), false);
        assertEq(address(ConfidencePool(created).stakeToken()), address(token));
        assertEq(factory.poolCountByAgreement(address(agreement)), 1);
    }

    function test_setPoolImplementation_success() external {
        ConfidencePool newImplementation = new ConfidencePool();
        vm.expectEmit(true, true, false, true);
        emit IConfidencePoolFactory.PoolImplementationUpdated(address(poolImplementation), address(newImplementation));

        factory.setPoolImplementation(address(newImplementation));
        assertEq(factory.poolImplementation(), address(newImplementation));
    }

    function testRevert_setPoolImplementation_zero() external {
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        factory.setPoolImplementation(address(0));
    }

    function testRevert_setPoolImplementation_notOwner() external {
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.setPoolImplementation(makeAddr("impl"));
    }

    function test_setDefaultOutcomeModerator_success() external {
        address newModerator = makeAddr("newModerator");
        vm.expectEmit(true, true, false, true);
        emit IConfidencePoolFactory.DefaultOutcomeModeratorUpdated(defaultModerator, newModerator);

        factory.setDefaultOutcomeModerator(newModerator);
        assertEq(factory.defaultOutcomeModerator(), newModerator);
    }

    function testRevert_setDefaultOutcomeModerator_zero() external {
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        factory.setDefaultOutcomeModerator(address(0));
    }

    function testRevert_setDefaultOutcomeModerator_notOwner() external {
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.setDefaultOutcomeModerator(makeAddr("mod"));
    }

    function testRevert_pause_notOwner() external {
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.pause();
    }

    function testRevert_unpause_notOwner() external {
        factory.pause();
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.unpause();
    }

    function testRevert_initialize_zeroRegistry() external {
        ConfidencePoolFactory impl = new ConfidencePoolFactory();
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ConfidencePoolFactory.initialize, (address(0), address(poolImplementation), defaultModerator)
            )
        );
    }

    function testRevert_initialize_zeroImpl() external {
        ConfidencePoolFactory impl = new ConfidencePoolFactory();
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ConfidencePoolFactory.initialize, (address(registry), address(0), defaultModerator))
        );
    }

    function testRevert_initialize_zeroModerator() external {
        ConfidencePoolFactory impl = new ConfidencePoolFactory();
        vm.expectRevert(IConfidencePoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ConfidencePoolFactory.initialize, (address(registry), address(poolImplementation), address(0))
            )
        );
    }

    function testRevert_authorizeUpgrade_notOwner() external {
        ConfidencePoolFactory nextImpl = new ConfidencePoolFactory();
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.upgradeToAndCall(address(nextImpl), "");
    }

    function testUpgradePreservesState() external {
        // Populate every factory storage slot, upgrade to a V2 that inherits V1's layout, then
        // assert all slots survive. Catches a future storage-layout regression (e.g. a new
        // variable added after `__gap` instead of before it).
        uint256 expiry = block.timestamp + 31 days;

        vm.prank(agreementOwner);
        address pool0 = factory.createPool(address(agreement), address(token), expiry, ONE, recovery, _scope());
        vm.prank(agreementOwner);
        address pool1 = factory.createPool(address(agreement), address(token), expiry, ONE, recovery, _scope());

        address registryBefore = address(factory.safeHarborRegistry());
        address implBefore = factory.poolImplementation();
        address moderatorBefore = factory.defaultOutcomeModerator();
        assertTrue(factory.allowedStakeToken(address(token)), "token allowlisted pre-upgrade");

        MockConfidencePoolFactoryV2 v2Impl = new MockConfidencePoolFactoryV2();
        factory.upgradeToAndCall(address(v2Impl), "");

        // V2-only function reachable through the proxy proves the implementation pointer moved.
        assertEq(MockConfidencePoolFactoryV2(address(factory)).version(), "v2", "v2 function callable");

        assertEq(address(factory.safeHarborRegistry()), registryBefore, "registry preserved");
        assertEq(factory.poolImplementation(), implBefore, "pool implementation preserved");
        assertEq(factory.defaultOutcomeModerator(), moderatorBefore, "default moderator preserved");
        assertTrue(factory.allowedStakeToken(address(token)), "allowlist mapping preserved");
        assertEq(factory.poolCountByAgreement(address(agreement)), 2, "pool count preserved");
        address[] memory pools = factory.getPoolsByAgreement(address(agreement));
        assertEq(pools.length, 2, "pool list length preserved");
        assertEq(pools[0], pool0, "pool[0] preserved");
        assertEq(pools[1], pool1, "pool[1] preserved");
        assertEq(factory.owner(), address(this), "owner preserved");
        assertEq(factory.pendingOwner(), address(0), "pendingOwner preserved");
    }

    function testOwnershipTransferIsTwoStep() external {
        // transferOwnership only sets pendingOwner; ownership moves on acceptOwnership.
        // A typo'd or inaccessible recipient can't grab the factory's admin levers.
        address newOwner = makeAddr("newOwner");
        factory.transferOwnership(newOwner);

        assertEq(factory.owner(), address(this));
        assertEq(factory.pendingOwner(), newOwner);

        address intruder = makeAddr("intruder");
        vm.prank(intruder);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, intruder));
        factory.acceptOwnership();

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);
        assertEq(factory.pendingOwner(), address(0));
    }
}
