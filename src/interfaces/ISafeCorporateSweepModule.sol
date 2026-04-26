// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  ISafeCorporateSweepModule
/// @notice External surface of the Zero-Balance Corporate Sweep Module.
/// @dev    The module is a Zodiac-style Safe Module: it never custodies funds.
///         All ERC-20 / Aave interactions execute through `execTransactionFromModule`
///         on the attached Safe so the Safe remains the on-chain owner of record.
interface ISafeCorporateSweepModule {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when the operating threshold (minimum idle balance) is updated.
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when a relayer is authorized or revoked by the Safe.
    event RelayerUpdated(address indexed relayer, bool authorized);

    /// @notice Emitted on a successful permissionless sweep into the yield target.
    event Swept(address indexed caller, uint256 amount, uint256 newSafeBalance);

    /// @notice Emitted when the Safe manually pushes funds into the yield target.
    event ManualSupplied(uint256 amount);

    /// @notice Emitted when the Safe manually pulls funds out of the yield target.
    event ManualWithdrawn(uint256 amount);

    /// @notice Emitted when JIT funding tops up the Safe ahead of an outgoing transaction.
    /// @param  caller     Address that triggered the JIT pull.
    /// @param  shortfall  Exact amount drawn from Aave back into the Safe.
    /// @param  txAmount   Outgoing transaction size the JIT was sized for.
    event JitWithdrawn(address indexed caller, uint256 shortfall, uint256 txAmount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotSafe();
    error NotAuthorizedRelayer();
    error ZeroAddress();
    error ZeroAmount();
    error NoSweepRequired();
    error NoShortfall();
    error UnderlyingMismatch();
    error ModuleNotEnabled();
    error SafeCallReverted();

    // ---------------------------------------------------------------------
    // Admin (Safe-only)
    // ---------------------------------------------------------------------

    /// @notice Updates the minimum USDC balance the Safe should retain at all times.
    /// @dev    Callable only by the Safe (i.e. via owner-signed Safe transaction).
    function setThreshold(uint256 _amount) external;

    /// @notice Authorizes (or revokes) an automation relayer for `executeSweep` / `jitWithdraw`.
    function setRelayer(address _relayer, bool _authorized) external;

    /// @notice Manually pushes `_amount` of underlying from the Safe into the yield target.
    function manualSupply(uint256 _amount) external;

    /// @notice Manually pulls `_amount` of underlying from the yield target back to the Safe.
    /// @dev    Pass `type(uint256).max` to withdraw the full aToken balance.
    function manualWithdraw(uint256 _amount) external;

    // ---------------------------------------------------------------------
    // Automation (relayer or Safe)
    // ---------------------------------------------------------------------

    /// @notice Sweeps any USDC balance above the operating threshold into Aave V3.
    /// @return supplied The amount of underlying supplied. Reverts if zero.
    function executeSweep() external returns (uint256 supplied);

    /// @notice Tops the Safe up to `_txAmount` of underlying by withdrawing the
    ///         exact shortfall from Aave V3. Designed to be batched immediately
    ///         before the outgoing Safe transaction in the same execution flow.
    /// @return shortfall The amount actually withdrawn from Aave.
    function jitWithdraw(uint256 _txAmount) external returns (uint256 shortfall);

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Address of the Safe this module is bound to.
    function safeAddress() external view returns (address);

    /// @notice Underlying stablecoin (e.g. USDC).
    function asset() external view returns (address);

    /// @notice Yield-bearing aToken (e.g. aUSDC).
    function aToken() external view returns (address);

    /// @notice Aave V3 Pool that custodies the supplied principal.
    function yieldTarget() external view returns (address);

    /// @notice Minimum idle balance to keep on the Safe.
    function operatingThreshold() external view returns (uint256);

    /// @notice Returns true if `account` is permitted to call automation entrypoints.
    function isRelayer(address account) external view returns (bool);

    /// @notice Returns the amount that would be supplied if `executeSweep` were called now.
    function previewSweepAmount() external view returns (uint256);

    /// @notice Returns the amount that `jitWithdraw(_txAmount)` would pull from Aave.
    function previewShortfall(uint256 _txAmount) external view returns (uint256);
}
