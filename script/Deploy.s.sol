// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ConfidencePool} from "src/ConfidencePool.sol";
import {ConfidencePoolFactory} from "src/ConfidencePoolFactory.sol";
import {MockConfidencePoolModerator} from "src/mocks/MockConfidencePoolModerator.sol";

contract Deploy is Script {
    function run() external returns (address implementation, address factoryProxy, address moderator) {
        address safeHarborRegistry = vm.envAddress("SAFE_HARBOR_REGISTRY");
        bool deployMockModerator = vm.envOr("DEPLOY_MOCK_MODERATOR", false);
        // Optional comma-separated allowlist for the factory's stake-token gate. If unset, the
        // factory ships with an empty allowlist and createPool reverts until the owner runs
        // `setStakeTokenAllowed` post-deploy.
        address[] memory initialStakeTokens = vm.envOr("INITIAL_STAKE_TOKENS", ",", new address[](0));

        vm.startBroadcast();

        if (deployMockModerator) {
            moderator = address(new MockConfidencePoolModerator());
        } else {
            moderator = vm.envAddress("DEFAULT_MODERATOR");
        }

        implementation = address(new ConfidencePool());

        ConfidencePoolFactory factoryImpl = new ConfidencePoolFactory();
        bytes memory initData =
            abi.encodeCall(ConfidencePoolFactory.initialize, (safeHarborRegistry, implementation, moderator));
        factoryProxy = address(new ERC1967Proxy(address(factoryImpl), initData));

        for (uint256 i; i < initialStakeTokens.length; ++i) {
            ConfidencePoolFactory(factoryProxy).setStakeTokenAllowed(initialStakeTokens[i], true);
        }

        vm.stopBroadcast();
    }
}
