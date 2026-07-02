// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IConfidencePool} from "src/interfaces/IConfidencePool.sol";
import {IConfidencePoolFactory} from "src/interfaces/IConfidencePoolFactory.sol";
import {IBattleChainSafeHarborRegistry} from "@battlechain/interface/IBattleChainSafeHarborRegistry.sol";
import {IAgreement} from "@battlechain/interface/IAgreement.sol";

// aderyn-fp-next-line(contract-locks-ether)
contract ConfidencePoolFactory is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    IConfidencePoolFactory
{
    IBattleChainSafeHarborRegistry public safeHarborRegistry;
    address public poolImplementation;
    address public defaultOutcomeModerator;
    /// @notice Tokens the factory owner has approved for use as a pool's stake token. Empty by
    /// default. Pools assume a standard ERC20 (no transfer fees, no rebasing); fee-on-transfer
    /// tokens silently under-pay every claim/withdraw, and fee-on-sender or negative-rebasing
    /// tokens erode the pool balance below tracked liabilities and permanently lock later claims.
    /// Checked only at `createPool` time, so de-listing a token does not affect existing pools.
    mapping(address token => bool allowed) public override allowedStakeToken;
    /// @notice All pools created for a given agreement, in creation order. An agreement may back
    /// many pools — each commits to its own (locked) scope, so duplicates are allowed and
    /// curated off-chain.
    mapping(address agreement => address[] pools) internal _poolsByAgreement;

    /// @dev Reserved for future state additions on upgrade. Append new variables before this
    /// gap and decrement its size accordingly; never reorder existing variables.
    // aderyn-fp-next-line(unused-state-variable)
    uint256[45] private __gap;

    uint256 private constant _MIN_EXPIRY_LEAD = 30 days;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IConfidencePoolFactory
    function initialize(address safeHarborRegistry_, address poolImplementation_, address defaultOutcomeModerator_)
        external
        initializer
    {
        if (safeHarborRegistry_ == address(0)) revert ZeroAddress();
        if (poolImplementation_ == address(0)) revert ZeroAddress();
        if (defaultOutcomeModerator_ == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __Pausable_init();

        safeHarborRegistry = IBattleChainSafeHarborRegistry(safeHarborRegistry_);
        poolImplementation = poolImplementation_;
        defaultOutcomeModerator = defaultOutcomeModerator_;
    }

    /// @inheritdoc IConfidencePoolFactory
    function createPool(
        address agreement,
        address stakeToken,
        uint256 expiry,
        uint256 minStake,
        address recoveryAddress,
        address[] calldata accounts
    ) external whenNotPaused returns (address pool) {
        if (agreement == address(0) || stakeToken == address(0)) revert ZeroAddress();
        if (recoveryAddress == address(0)) revert ZeroAddress();
        if (!allowedStakeToken[stakeToken]) revert StakeTokenNotAllowed();
        if (expiry < block.timestamp + _MIN_EXPIRY_LEAD) revert ExpiryTooSoon();
        // aderyn-fp-next-line(reentrancy-state-change)
        if (!safeHarborRegistry.isAgreementValid(agreement)) revert InvalidAgreement();
        // aderyn-fp-next-line(reentrancy-state-change)
        if (IAgreement(agreement).owner() != msg.sender) revert UnauthorizedCreator();

        // Salt incorporates the per-agreement index so an agreement can back many pools while
        // keeping deterministic, collision-free clone addresses.
        bytes32 salt = keccak256(abi.encode(agreement, _poolsByAgreement[agreement].length));
        pool = Clones.cloneDeterministic(poolImplementation, salt);

        // aderyn-fp-next-line(reentrancy-state-change)
        IConfidencePool(pool)
            .initialize(
                agreement,
                stakeToken,
                address(safeHarborRegistry),
                defaultOutcomeModerator,
                expiry,
                minStake,
                recoveryAddress,
                msg.sender,
                accounts
            );

        _poolsByAgreement[agreement].push(pool);
        emit PoolCreated(
            agreement,
            pool,
            stakeToken,
            expiry,
            minStake,
            recoveryAddress,
            defaultOutcomeModerator,
            address(safeHarborRegistry)
        );
    }

    /// @inheritdoc IConfidencePoolFactory
    function getPoolsByAgreement(address agreement) external view returns (address[] memory) {
        return _poolsByAgreement[agreement];
    }

    /// @inheritdoc IConfidencePoolFactory
    function poolCountByAgreement(address agreement) external view returns (uint256) {
        return _poolsByAgreement[agreement].length;
    }

    /// @inheritdoc IConfidencePoolFactory
    // aderyn-ignore-next-line(centralization-risk)
    function setSafeHarborRegistry(address newSafeHarborRegistry) external onlyOwner {
        if (newSafeHarborRegistry == address(0)) revert ZeroAddress();
        address old = address(safeHarborRegistry);
        safeHarborRegistry = IBattleChainSafeHarborRegistry(newSafeHarborRegistry);
        emit SafeHarborRegistryUpdated(old, newSafeHarborRegistry);
    }

    /// @inheritdoc IConfidencePoolFactory
    // aderyn-ignore-next-line(centralization-risk)
    function setPoolImplementation(address newPoolImplementation) external onlyOwner {
        if (newPoolImplementation == address(0)) revert ZeroAddress();
        address old = poolImplementation;
        poolImplementation = newPoolImplementation;
        emit PoolImplementationUpdated(old, newPoolImplementation);
    }

    /// @inheritdoc IConfidencePoolFactory
    // aderyn-ignore-next-line(centralization-risk)
    function setDefaultOutcomeModerator(address newDefaultOutcomeModerator) external onlyOwner {
        if (newDefaultOutcomeModerator == address(0)) revert ZeroAddress();
        address old = defaultOutcomeModerator;
        defaultOutcomeModerator = newDefaultOutcomeModerator;
        emit DefaultOutcomeModeratorUpdated(old, newDefaultOutcomeModerator);
    }

    /// @inheritdoc IConfidencePoolFactory
    // aderyn-ignore-next-line(centralization-risk)
    function setStakeTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedStakeToken[token] = allowed;
        emit StakeTokenAllowedUpdated(token, allowed);
    }

    /// @inheritdoc IConfidencePoolFactory
    // aderyn-ignore-next-line(centralization-risk)
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IConfidencePoolFactory
    // aderyn-ignore-next-line(centralization-risk)
    function unpause() external onlyOwner {
        _unpause();
    }

    // aderyn-ignore-next-line(centralization-risk) aderyn-ignore-next-line(empty-block)
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
