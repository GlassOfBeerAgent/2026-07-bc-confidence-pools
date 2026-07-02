// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IAgreement} from "@battlechain/interface/IAgreement.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {IBattleChainSafeHarborRegistry} from "@battlechain/interface/IBattleChainSafeHarborRegistry.sol";

/// @notice Fork drift test: verifies the BattleChain interfaces we consume (from the
/// `battlechain-safe-harbor-contracts` submodule) still match the live deployed contracts on
/// BattleChain testnet — the submodule is pinned to a commit that can drift from what's deployed.
/// Catches:
///   - function-signature drift (rename / new arg / new return) via selector mismatches
///   - enum ordinal drift (e.g. a new state inserted before existing ones shifts every later
///     ordinal — our name-based comparisons keep compiling but silently match the wrong state)
///   - back-pointer integrity between the three registries
///
/// Runs only when the env var `BATTLECHAIN_TESTNET_RPC` is set (the `battlechain_testnet` alias in
/// `foundry.toml` resolves to it). Default `forge test` invocations skip it.
///
/// To run locally:
///   BATTLECHAIN_TESTNET_RPC=https://testnet.battlechain.com forge test --match-path 'test/fork/*'
contract BattleChainInterfaceDriftForkTest is Test {
    // Deployed contracts on BattleChain testnet (chainId 627).
    address internal constant SAFE_HARBOR_REGISTRY = 0x0a652e265336a0296816aC4D8400880e3E537C24;
    address internal constant ATTACK_REGISTRY = 0xdD029a6374095EEb4c47a2364Ce1D0f47f007350;
    address internal constant AGREEMENT_FACTORY = 0x2Bee2970f10FDc2aeA28662BB6F6A501278Ebd46;

    // A real agreement on the testnet ("BattleChain Starter Demo"). Stable from at least block
    // 10,100 onward at state UNDER_ATTACK (ordinal 3 in the ContractState enum) with a single
    // BattleChain scope address.
    address internal constant DEMO_AGREEMENT = 0xE550894617Ac4C1bbc019C2AA5D47495a0F07716;
    address internal constant DEMO_AGREEMENT_OWNER = 0x3EfcFc441c1e70A141850D4da0d5C7314952Fc3d;
    address internal constant DEMO_AGREEMENT_IN_SCOPE = 0xeEFCFBeFCE9a8fbB20694483DA9E6fBbcD5084A7;

    // Pinned block — deterministic. Far enough back that state changes upstream don't make the
    // test flaky, recent enough to catch interface drift promptly. Bump as needed.
    uint256 internal constant PIN_BLOCK = 16000;

    function setUp() public {
        // Skip entirely unless the RPC env var is set. The rpc-endpoints alias in foundry.toml
        // resolves "battlechain_testnet" to ${BATTLECHAIN_TESTNET_RPC}.
        try vm.envString("BATTLECHAIN_TESTNET_RPC") returns (string memory) {
            vm.createSelectFork("battlechain_testnet", PIN_BLOCK);
        } catch {
            vm.skip(true);
        }
    }

    function testSafeHarborRegistryRoundTrips() external view {
        IBattleChainSafeHarborRegistry r = IBattleChainSafeHarborRegistry(SAFE_HARBOR_REGISTRY);

        // getAttackRegistry()
        assertEq(r.getAttackRegistry(), ATTACK_REGISTRY, "getAttackRegistry signature drift");

        // getAgreementFactory()
        assertEq(r.getAgreementFactory(), AGREEMENT_FACTORY, "getAgreementFactory signature drift");

        // isAgreementValid(address) — known-valid agreement
        assertTrue(r.isAgreementValid(DEMO_AGREEMENT), "demo agreement should be valid");
        // ... and known-invalid (random address)
        assertFalse(r.isAgreementValid(address(0xdead)), "random address should not be valid");
    }

    function testAttackRegistryRoundTrips() external view {
        IAttackRegistry r = IAttackRegistry(ATTACK_REGISTRY);

        // Back-pointer integrity: attack-registry → safe-harbor → attack-registry round-trip.
        assertEq(
            IBattleChainSafeHarborRegistry(SAFE_HARBOR_REGISTRY).getAttackRegistry(),
            ATTACK_REGISTRY,
            "registry round-trip"
        );

        // getAttackModerator(address) — per-agreement signature.
        assertEq(r.getAttackModerator(DEMO_AGREEMENT), DEMO_AGREEMENT_OWNER, "getAttackModerator(address) signature");

        // getAgreementState(address) — return type is our ContractState enum.
        IAttackRegistry.ContractState state = r.getAgreementState(DEMO_AGREEMENT);
        // Pinned block has the demo agreement in UNDER_ATTACK. If a new enum value is inserted
        // before UNDER_ATTACK upstream, this assertion will fail because the uint8 we get back
        // will deserialise into a different enum value (matched by ordinal, not by name).
        assertEq(
            uint256(state), uint256(IAttackRegistry.ContractState.UNDER_ATTACK), "demo agreement state ordinal drift"
        );
    }

    function testAgreementRoundTrips() external view {
        IAgreement a = IAgreement(DEMO_AGREEMENT);

        // owner() from Ownable
        assertEq(a.owner(), DEMO_AGREEMENT_OWNER, "agreement owner signature drift");

        // isContractInScope(address) — known in-scope account
        assertTrue(a.isContractInScope(DEMO_AGREEMENT_IN_SCOPE), "known account should be in scope");
        // ... and known out-of-scope (random address)
        assertFalse(a.isContractInScope(address(0xfeed)), "random address should not be in scope");
    }

    function testEnumOrdinalsAreStable() external view {
        // Belt-and-braces: even with no agreement to query, assert each ContractState enum value's
        // ordinal matches the upstream order. Encoded as a separate test so a drift here surfaces
        // clearly in CI output instead of being conflated with a registry round-trip failure.
        assertEq(uint256(IAttackRegistry.ContractState.NOT_DEPLOYED), 0, "NOT_DEPLOYED ordinal");
        assertEq(uint256(IAttackRegistry.ContractState.NEW_DEPLOYMENT), 1, "NEW_DEPLOYMENT ordinal");
        assertEq(uint256(IAttackRegistry.ContractState.ATTACK_REQUESTED), 2, "ATTACK_REQUESTED ordinal");
        assertEq(uint256(IAttackRegistry.ContractState.UNDER_ATTACK), 3, "UNDER_ATTACK ordinal");
        assertEq(uint256(IAttackRegistry.ContractState.PROMOTION_REQUESTED), 4, "PROMOTION_REQUESTED ordinal");
        assertEq(uint256(IAttackRegistry.ContractState.PRODUCTION), 5, "PRODUCTION ordinal");
        assertEq(uint256(IAttackRegistry.ContractState.CORRUPTED), 6, "CORRUPTED ordinal");
    }
}
