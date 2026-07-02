// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IConfidencePoolFactory {
    event PoolCreated(
        address indexed agreement,
        address indexed pool,
        address stakeToken,
        uint256 expiry,
        uint256 minStake,
        address recoveryAddress,
        address outcomeModerator,
        address safeHarborRegistry
    );
    event SafeHarborRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event PoolImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);
    event DefaultOutcomeModeratorUpdated(address indexed oldModerator, address indexed newModerator);
    event StakeTokenAllowedUpdated(address indexed token, bool allowed);

    error InvalidAgreement();
    error ExpiryTooSoon();
    error ZeroAddress();
    error UnauthorizedCreator();
    error StakeTokenNotAllowed();

    function initialize(address safeHarborRegistry, address poolImplementation, address defaultOutcomeModerator)
        external;

    function createPool(
        address agreement,
        address stakeToken,
        uint256 expiry,
        uint256 minStake,
        address recoveryAddress,
        address[] calldata accounts
    ) external returns (address pool);

    function setSafeHarborRegistry(address newSafeHarborRegistry) external;

    function setPoolImplementation(address newPoolImplementation) external;

    function setDefaultOutcomeModerator(address newDefaultOutcomeModerator) external;

    /// @notice Allow or disallow `token` as a pool stake token. Pools assume a standard ERC20;
    /// fee-on-transfer and rebasing tokens break payout accounting, so only owner-approved tokens
    /// may back a pool. Checked at `createPool` time only.
    function setStakeTokenAllowed(address token, bool allowed) external;

    function allowedStakeToken(address token) external view returns (bool);

    function pause() external;

    function unpause() external;

    /// @notice Returns all pools created for `agreement`, in creation order. An agreement may
    /// back multiple pools, each with its own committed scope.
    function getPoolsByAgreement(address agreement) external view returns (address[] memory);

    /// @notice Number of pools created for `agreement`.
    function poolCountByAgreement(address agreement) external view returns (uint256);
}
