// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";

/// @notice Minimal test double for the BattleChain AttackRegistry. The pool reaches it by address
/// and only calls `getAgreementState`; `getAttackModerator` is implemented for the fork drift
/// test. Plus test-only setters to stage both. It intentionally does NOT inherit `IAttackRegistry`
/// — matching selectors is sufficient for an address-cast call site, and inheriting the full
/// interface would force struct-typed stubs that clash under `via_ir`. The `ContractState` enum is
/// referenced through the imported interface so it stays in lockstep with upstream.
contract MockAttackRegistry {
    IAttackRegistry.ContractState internal state;
    address internal moderator;

    function setAgreementState(IAttackRegistry.ContractState nextState) external {
        state = nextState;
    }

    function setAttackModerator(address nextModerator) external {
        moderator = nextModerator;
    }

    function getAgreementState(address) external view returns (IAttackRegistry.ContractState) {
        return state;
    }

    function getAttackModerator(address) external view returns (address) {
        return moderator;
    }
}
