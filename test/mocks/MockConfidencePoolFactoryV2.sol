// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfidencePoolFactory} from "src/ConfidencePoolFactory.sol";

/// @notice Test-only V2 of `ConfidencePoolFactory`. Inherits the V1 storage layout unchanged
/// and adds a sentinel function so a UUPS upgrade test can prove the implementation pointer
/// moved while V1 state survived.
contract MockConfidencePoolFactoryV2 is ConfidencePoolFactory {
    function version() external pure returns (string memory) {
        return "v2";
    }
}
