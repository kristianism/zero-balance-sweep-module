// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  ISafeCorporateSweepModule
/// @notice External surface of the Zero-Balance Corporate Sweep Module.
/// @dev    Normal treasury flows execute through `execTransactionFromModule`
///         on the attached Safe so the Safe remains the on-chain owner of record.
///         Safe-only recovery functions return assets sent directly to the module.
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
    /// @param amount Actual underlying returned to the Safe.
    event ManualWithdrawn(uint256 amount);

    /// @notice Emitted when the Safe recovers an ERC-20 sent directly to the module.
    event TokenRecovered(address indexed token, uint256 amount);

    /// @notice Emitted when the Safe recovers native currency forced into the module.
    event NativeRecovered(uint256 amount);

    /// @notice Emitted when JIT funding tops up the Safe ahead of an outgoing transaction.
    /// @param  caller     Address that triggered the JIT pull.
    /// @param  shortfall  Amount drawn from Aave back into the Safe.
    /// @param  txAmount   Outgoing transaction size the JIT was sized for.
    event JitWithdrawn(address indexed caller, uint256 shortfall, uint256 txAmount);

    /// @notice Emitted when the Safe sets a relayer-consumable JIT intent.
    event JitIntentSet(uint256 indexed nonce, uint256 amount, uint256 deadline);

    /// @notice Emitted when the Safe invalidates an unconsumed relayer JIT intent.
    event JitIntentCancelled(uint256 indexed nonce);

    /// @notice Emitted when a relayer top-up is protected from automated resweeping.
    event JitBalanceReserved(uint256 indexed nonce, uint256 balance, uint256 deadline);

    /// @notice Emitted when the Safe releases a funded JIT balance reservation.
    event JitReservationCleared(uint256 indexed nonce);

    /// @notice Emitted when relayer guardrails are updated.
    event RelayerGuardrailsUpdated(
        uint256 maxJitWithdrawPerCall, uint256 maxSweepPerCall, uint256 relayerCooldown
    );

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
    error PoolMismatch();
    error NotContract();
    error ModuleNotEnabled();
    error SafeCallReverted();
    error TokenCallFailed();
    error NoPendingJitIntent();
    error JitReservationActive();
    error JitIntentExpired();
    error JitIntentAmountMismatch();
    error RelayerCooldownActive();
    error SweepCapExceeded();
    error JitCapExceeded();
    error InsufficientPostWithdrawBalance();
    error NativeRecoveryFailed();

    // ---------------------------------------------------------------------
    // Admin (Safe-only)
    // ---------------------------------------------------------------------

    /// @notice Updates the minimum asset balance retained by automated sweeps.
    /// @dev    Callable only by the Safe, including owner-authorized transactions
    ///         and calls initiated through another enabled Safe module.
    function setThreshold(uint256 _amount) external;

    /// @notice Authorizes (or revokes) an automation relayer for `executeSweep` / `jitWithdraw`.
    function setRelayer(address _relayer, bool _authorized) external;

    /// @notice Sets a one-time relayer JIT intent that must be consumed before `deadline`.
    /// @dev    Safe-only. Reverts while a funded reservation is active; release it explicitly first.
    function setJitIntent(uint256 _amount, uint256 _deadline) external;

    /// @notice Invalidates a pending intent and releases any funded reservation.
    /// @dev    Safe-only emergency/acknowledgement control. Safe to call when neither exists.
    function cancelJitIntent() external;

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

    /// @notice Recovers an ERC-20 sent directly to the module and returns it to the Safe.
    function recoverToken(address _token, uint256 _amount) external;

    /// @notice Recovers native currency forced into the module and returns it to the Safe.
    function recoverNative() external;

    // ---------------------------------------------------------------------
    // Automation (relayer or Safe)
    // ---------------------------------------------------------------------

    /// @notice Sweeps any USDC balance above the operating threshold into Aave V3.
    /// @return supplied The amount of underlying supplied. Reverts if zero.
    function executeSweep() external returns (uint256 supplied);

    /// @notice Tops the Safe up to `_txAmount` of underlying by withdrawing the
    ///         exact shortfall from Aave V3. A Safe call can batch this with the
    ///         outgoing payment; a relayer call only performs the top-up.
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

    /// @notice Minimum funded JIT balance protected from relayer sweeps.
    function reservedJitBalance() external view returns (uint256);

    /// @notice Deadline after which the funded JIT reservation stops applying.
    function jitReservationDeadline() external view returns (uint256);

    /// @notice Whether a funded JIT reservation is currently effective.
    function hasActiveJitReservation() external view returns (bool);

    /// @notice Returns the amount an authorized relayer would supply now after reservation and cap limits.
    function previewSweepAmount() external view returns (uint256);

    /// @notice Returns the amount that `jitWithdraw(_txAmount)` would pull from Aave.
    function previewShortfall(uint256 _txAmount) external view returns (uint256);
}
