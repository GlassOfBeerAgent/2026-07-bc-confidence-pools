// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal test double for the BattleChain Agreement. The pool reaches it by address and
/// only calls `owner` / `isContractInScope`, so the mock implements just those (plus a test-only
/// scope setter). It intentionally does NOT inherit `IAgreement` — matching selectors is
/// sufficient for an address-cast call site, and inheriting the full interface would force
/// struct-typed stubs that clash under `via_ir`.
contract MockAgreement {
    address internal agreementOwner;
    mapping(address account => bool inScope) internal _inScope;

    constructor(address owner_) {
        agreementOwner = owner_;
    }

    function owner() external view returns (address) {
        return agreementOwner;
    }

    /// @notice Test-only setter. Stages which BattleChain accounts the agreement reports as
    /// in-scope via `isContractInScope`.
    function setContractInScope(address account, bool inScope) external {
        _inScope[account] = inScope;
    }

    function isContractInScope(address contractAddress) external view returns (bool) {
        return _inScope[contractAddress];
    }
}
