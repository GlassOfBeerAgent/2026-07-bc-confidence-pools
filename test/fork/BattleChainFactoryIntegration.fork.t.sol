// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {ConfidencePoolFactory} from "src/ConfidencePoolFactory.sol";
import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @notice End-to-end integration smoke test against the LIVE BattleChain testnet registry stack.
/// Where `BattleChainInterfaceDrift.fork.t.sol` verifies ABI shape, this file verifies that our
/// factory can actually create a pool against the real `SafeHarborRegistry`, `AttackRegistry`,
/// and `Agreement` contracts — exercising the `isAgreementValid` / `owner()` / `isContractInScope`
/// call path end-to-end.
///
/// Runs only when `BATTLECHAIN_TESTNET_RPC` is set (gated via `vm.skip(true)` in `setUp`).
contract BattleChainFactoryIntegrationForkTest is Test {
    // Live deployments on BattleChain testnet (chainId 627).
    address internal constant SAFE_HARBOR_REGISTRY = 0x0a652e265336a0296816aC4D8400880e3E537C24;
    // The demo agreement and its real in-scope account, owned by 0x3EfcF...Fc3d. Stable at the
    // pinned block; see BattleChainInterfaceDrift.fork.t.sol for the same constants.
    address internal constant DEMO_AGREEMENT = 0xE550894617Ac4C1bbc019C2AA5D47495a0F07716;
    address internal constant DEMO_AGREEMENT_OWNER = 0x3EfcFc441c1e70A141850D4da0d5C7314952Fc3d;
    address internal constant DEMO_AGREEMENT_IN_SCOPE = 0xeEFCFBeFCE9a8fbB20694483DA9E6fBbcD5084A7;
    address internal constant OUT_OF_SCOPE = address(0xBADCAFE);

    uint256 internal constant PIN_BLOCK = 16000;

    ConfidencePoolFactory internal factory;
    ConfidencePool internal poolImpl;
    MockERC20 internal stakeToken;

    address internal moderator = makeAddr("moderator");
    address internal recovery = makeAddr("recovery");

    function setUp() public {
        try vm.envString("BATTLECHAIN_TESTNET_RPC") returns (string memory) {
            vm.createSelectFork("battlechain_testnet", PIN_BLOCK);
        } catch {
            vm.skip(true);
            return;
        }

        // Deploy our factory + pool implementation into the forked EVM, pointed at the live
        // SafeHarborRegistry. The factory itself is not deployed on BattleChain yet — this is
        // a dry run of the production deploy against the real registry contracts.
        poolImpl = new ConfidencePool();
        ConfidencePoolFactory factoryImpl = new ConfidencePoolFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(ConfidencePoolFactory.initialize, (SAFE_HARBOR_REGISTRY, address(poolImpl), moderator))
        );
        factory = ConfidencePoolFactory(address(proxy));

        // Allowlist a fresh stake token so `createPool`'s allowlist gate passes.
        stakeToken = new MockERC20();
        factory.setStakeTokenAllowed(address(stakeToken), true);
    }

    function testCreatePoolAgainstLiveAgreementSucceeds() external {
        uint256 expiry = block.timestamp + 31 days;
        address[] memory accounts = new address[](1);
        accounts[0] = DEMO_AGREEMENT_IN_SCOPE;

        // Impersonate the real agreement owner so `IAgreement.owner() == msg.sender` passes.
        vm.prank(DEMO_AGREEMENT_OWNER);
        address pool = factory.createPool(DEMO_AGREEMENT, address(stakeToken), expiry, 1e18, recovery, accounts);

        // End-to-end checks: the pool exists, its scope was validated against the live
        // agreement's `isContractInScope`, and the factory's bookkeeping records it.
        assertTrue(pool != address(0), "pool clone created");
        assertEq(IConfidencePool(pool).getScopeAccounts().length, 1, "scope account count");
        assertEq(IConfidencePool(pool).getScopeAccounts()[0], DEMO_AGREEMENT_IN_SCOPE, "scope account identity");
        assertTrue(IConfidencePool(pool).isAccountInScope(DEMO_AGREEMENT_IN_SCOPE), "scope membership flag");
        assertEq(factory.poolCountByAgreement(DEMO_AGREEMENT), 1, "factory bookkeeping");
    }

    function testCreatePoolRejectsAccountNotInLiveAgreementScope() external {
        // Pass an account the live agreement does NOT know about. `_replaceScope` calls
        // `IAgreement.isContractInScope(account)`, which must return false → revert
        // AccountNotInAgreementScope.
        uint256 expiry = block.timestamp + 31 days;
        address[] memory accounts = new address[](1);
        accounts[0] = OUT_OF_SCOPE;

        vm.prank(DEMO_AGREEMENT_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IConfidencePool.AccountNotInAgreementScope.selector, OUT_OF_SCOPE));
        factory.createPool(DEMO_AGREEMENT, address(stakeToken), expiry, 1e18, recovery, accounts);
    }
}
