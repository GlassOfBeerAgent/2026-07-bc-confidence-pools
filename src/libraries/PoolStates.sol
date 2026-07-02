// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared pool outcome states.
library PoolStates {
    enum Outcome {
        UNRESOLVED,
        SURVIVED,
        CORRUPTED,
        EXPIRED
    }

    /// @notice Returns true when an outcome is terminal.
    function isTerminal(Outcome outcome) internal pure returns (bool) {
        return outcome != Outcome.UNRESOLVED;
    }
}
