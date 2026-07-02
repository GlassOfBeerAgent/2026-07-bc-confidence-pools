// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAttackRegistry} from "test/mocks/MockAttackRegistry.sol";
import {MockSafeHarborRegistry} from "test/mocks/MockSafeHarborRegistry.sol";
import {MockAgreement} from "test/mocks/MockAgreement.sol";

contract BaseConfidencePoolTest is Test {
    uint256 internal constant ONE = 1e18;
    address internal constant DEFAULT_SCOPE_ACCOUNT = address(0xC0FFEE);

    MockERC20 internal token;
    MockAttackRegistry internal attackRegistry;
    MockSafeHarborRegistry internal safeHarborRegistry;
    MockAgreement internal agreementContract;
    ConfidencePool internal pool;

    address internal agreement;
    address internal moderator = makeAddr("moderator");
    address internal recovery = makeAddr("recovery");
    address internal attacker = makeAddr("attacker");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    /// @dev Realistic base timestamp (~2025-06-15) so the whole suite exercises the k=2 bonus
    /// math and the uint32 timestamp casts at production-scale `block.timestamp` (~1.75e9), where
    /// `T²·stake` magnitudes and any uint32 truncation risk actually live. Foundry's default base
    /// of 1 would run every timestamp ~12 orders of magnitude too small to stress either.
    uint256 internal constant BASE_TIMESTAMP = 1_750_000_000;

    function setUp() public virtual {
        vm.warp(BASE_TIMESTAMP);
        token = new MockERC20();
        attackRegistry = new MockAttackRegistry();
        safeHarborRegistry = new MockSafeHarborRegistry();
        // Deploy a real MockAgreement so `childContractScope` queries during scope validation
        // resolve to the staged enum values. Owner doesn't matter for direct pool tests; the
        // factory tests use their own MockAgreement with the correct owner.
        agreementContract = new MockAgreement(address(this));
        agreement = address(agreementContract);
        // Seed the default account as in-scope on the agreement so the default pool scope
        // passes validation.
        agreementContract.setContractInScope(DEFAULT_SCOPE_ACCOUNT, true);

        safeHarborRegistry.setAttackRegistry(address(attackRegistry));
        safeHarborRegistry.setAgreementValid(agreement, true);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);

        ConfidencePool implementation = new ConfidencePool();
        pool = ConfidencePool(Clones.clone(address(implementation)));
        pool.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    function _deployPool() internal returns (ConfidencePool deployedPool) {
        ConfidencePool implementation = new ConfidencePool();
        deployedPool = ConfidencePool(Clones.clone(address(implementation)));
        deployedPool.initialize(
            agreement,
            address(token),
            address(safeHarborRegistry),
            moderator,
            block.timestamp + 31 days,
            ONE,
            recovery,
            address(this),
            _defaultScope()
        );
    }

    /// @dev Convenience helper: a one-account scope using the default account seeded in `setUp`.
    /// Most tests don't care about scope contents, just that something is published.
    function _defaultScope() internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = DEFAULT_SCOPE_ACCOUNT;
    }

    function _stake(address user, uint256 amount) internal {
        _stakeRaw(user, amount);
    }

    function _stakeRaw(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(pool), amount);
        pool.stake(amount);
        vm.stopPrank();
    }

    function _contributeBonus(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(pool), amount);
        pool.contributeBonus(amount);
        vm.stopPrank();
    }

    /// @dev Transition the registry through UNDER_ATTACK (poking to seal `riskWindowStart`).
    /// `flagOutcome(CORRUPTED, ...)` requires an observed risk window, and bonus payouts pay
    /// zero without one — tests that need either need to call this before terminal observation.
    function _passThroughUnderAttack() internal {
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.UNDER_ATTACK);
        pool.pokeRiskWindow();
    }

    function _withdraw(address user) internal {
        vm.prank(user);
        pool.withdraw();
    }
}
