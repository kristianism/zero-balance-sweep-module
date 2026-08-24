// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IAaveV3Pool
/// @notice Subset of the Aave V3 Pool surface used by the sweep module.
/// @dev    Full ABI: https://github.com/aave-dao/aave-v3-origin
interface IAaveV3Pool {
    /// @notice Supplies `amount` of `asset` into the reserve, minting an
    ///         equivalent amount of aTokens to `onBehalfOf`.
    /// @param  asset         Underlying ERC-20 (e.g. USDC).
    /// @param  amount        Units of `asset` to supply (in token decimals).
    /// @param  onBehalfOf    Recipient of the aTokens. For the sweep module
    ///                       this is always the Safe address.
    /// @param  referralCode  Deprecated; pass 0.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Burns aTokens from `msg.sender` and returns the underlying to `to`.
    /// @param  asset   Underlying ERC-20.
    /// @param  amount  Units to withdraw, or `type(uint256).max` for full balance.
    /// @param  to      Recipient of the withdrawn underlying.
    /// @return The actual amount withdrawn (relevant when passing `max`).
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title  IAToken
/// @notice Minimal aToken surface used to validate constructor wiring.
interface IAToken {
    /// @notice Aave V3 Pool that controls this aToken reserve.
    function POOL() external view returns (address);

    /// @notice Returns the underlying asset address backing this aToken.
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    /// @notice Returns the rebased (principal + accrued interest) balance of `user`.
    function balanceOf(address user) external view returns (uint256);
}
