// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal test double for the BattleChain SafeHarborRegistry. The pool/factory reach it
/// by address and call `getAttackRegistry` (pool) and `isAgreementValid` (pool + factory);
/// `getAgreementFactory` is implemented for the fork drift test. Plus test-only setters. It
/// intentionally does NOT inherit `IBattleChainSafeHarborRegistry` — matching selectors is
/// sufficient for an address-cast call site.
contract MockSafeHarborRegistry {
    address internal attackRegistry;
    address internal agreementFactory;
    mapping(address => bool) internal validAgreement;

    function setAttackRegistry(address nextAttackRegistry) external {
        attackRegistry = nextAttackRegistry;
    }

    function setAgreementFactory(address nextAgreementFactory) external {
        agreementFactory = nextAgreementFactory;
    }

    function setAgreementValid(address agreement, bool valid) external {
        validAgreement[agreement] = valid;
    }

    function getAttackRegistry() external view returns (address) {
        return attackRegistry;
    }

    function getAgreementFactory() external view returns (address) {
        return agreementFactory;
    }

    function isAgreementValid(address agreement) external view returns (bool) {
        return validAgreement[agreement];
    }
}
