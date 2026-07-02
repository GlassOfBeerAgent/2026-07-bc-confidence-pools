// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {PoolStates} from "src/libraries/PoolStates.sol";

/// @notice Testnet-only moderator that lets anyone flag outcomes on any pool wired to it.
/// @dev Do NOT deploy to mainnet. Agreement-state checks still run on the pool itself, so
/// the underlying attack registry must already be in the expected state.
contract MockConfidencePoolModerator {
    event OutcomeFlagged(
        address indexed caller, address indexed pool, PoolStates.Outcome outcome, bool goodFaith, address attacker
    );

    function flag(address pool, PoolStates.Outcome outcome, bool goodFaith, address attacker) public {
        IConfidencePool(pool).flagOutcome(outcome, goodFaith, attacker);
        emit OutcomeFlagged(msg.sender, pool, outcome, goodFaith, attacker);
    }

    function flagSurvived(address pool) external {
        flag(pool, PoolStates.Outcome.SURVIVED, false, address(0));
    }

    function flagCorruptedGoodFaith(address pool, address attacker) external {
        flag(pool, PoolStates.Outcome.CORRUPTED, true, attacker);
    }

    function flagCorruptedBadFaith(address pool) external {
        flag(pool, PoolStates.Outcome.CORRUPTED, false, address(0));
    }
}
