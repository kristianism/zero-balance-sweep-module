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
    /// @param  shortfall  Amount drawn from Aave back into the Safe.
    /// @param  txAmount   Outgoing transaction size the JIT was sized for.
    event JitWithdrawn(address indexed caller, uint256 shortfall, uint256 txAmount);

    /// @notice Emitted when the Safe sets a relayer-consumable JIT intent.
    event JitIntentSet(uint256 indexed nonce, uint256 amount, uint256 deadline);

    /// @notice Emitted when relayer guardrails are updated.
    event RelayerGuardrailsUpdated(uint256 maxJitWithdrawPerCall, uint256 maxSweepPerCall, uint256 relayerCooldown);

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
    error NoPendingJitIntent();
    error JitIntentExpired();
    error JitIntentAmountMismatch();
    error RelayerCooldownActive();
    error SweepCapExceeded();
    error JitCapExceeded();
    error InsufficientPostWithdrawBalance();

    // ---------------------------------------------------------------------
    // Admin (Safe-only)
    // ---------------------------------------------------------------------

    /// @notice Updates the minimum USDC balance the Safe should retain at all times.
    /// @dev    Callable only by the Safe (i.e. via owner-signed Safe transaction).
    function setThreshold(uint256 _amount) external;

    /// @notice Authorizes (or revokes) an automation relayer for `executeSweep` / `jitWithdraw`.
    function setRelayer(address _relayer, bool _authorized) external;

    /// @notice Sets a one-time relayer JIT intent that must be consumed before `deadline`.
    /// @dev    Safe-only operation for binding relayer JIT calls to treasury intent.
    function setJitIntent(uint256 _amount, uint256 _deadline) external;

    /// @notice Sets guardrails for relayer-triggered automation calls.
    /// @dev    Any max value set to 0 means "unlimited".
    function setRelayerGuardrails(
        uint256 _maxJitWithdrawPerCall,
        uint256 _maxSweepPerCall,
        uint256 _relayerCooldown
    ) external;

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
    function SAFE_ADDRESS() external view returns (address);

    /// @notice Underlying stablecoin (e.g. USDC).
    function ASSET() external view returns (address);

    /// @notice Yield-bearing aToken (e.g. aUSDC).
    function A_TOKEN() external view returns (address);

    /// @notice Aave V3 Pool that custodies the supplied principal.
    function YIELD_TARGET() external view returns (address);

    /// @notice Minimum idle balance to keep on the Safe.
    function operatingThreshold() external view returns (uint256);

    /// @notice Returns true if `account` is permitted to call automation entrypoints.
    function isRelayer(address account) external view returns (bool);

    /// @notice Max relayer-triggered JIT amount per call (0 means unlimited).
    function maxJitWithdrawPerCall() external view returns (uint256);

    /// @notice Max relayer-triggered sweep amount per call (0 means unlimited).
    function maxSweepPerCall() external view returns (uint256);

    /// @notice Minimum seconds between relayer-triggered automation calls.
    function relayerCooldown() external view returns (uint256);

    /// @notice Last timestamp when relayer-triggered automation ran.
    function lastRelayerActionAt() external view returns (uint256);

    /// @notice Current pending JIT intent nonce.
    function jitIntentNonce() external view returns (uint256);

    /// @notice Current pending JIT intent amount.
    function jitIntentAmount() external view returns (uint256);

    /// @notice Current pending JIT intent deadline.
    function jitIntentDeadline() external view returns (uint256);

    /// @notice Whether a relayer-consumable JIT intent is currently active.
    function hasPendingJitIntent() external view returns (bool);

    /// @notice Returns the amount that would be supplied if `executeSweep` were called now.
    function previewSweepAmount() external view returns (uint256);

    /// @notice Returns the amount that `jitWithdraw(_txAmount)` would pull from Aave.
    function previewShortfall(uint256 _txAmount) external view returns (uint256);
}
