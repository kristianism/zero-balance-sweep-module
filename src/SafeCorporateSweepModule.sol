// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Enum, ISafe} from "./interfaces/ISafe.sol";
import {IAaveV3Pool, IAToken} from "./interfaces/IAaveV3Pool.sol";
import {ISafeCorporateSweepModule} from "./interfaces/ISafeCorporateSweepModule.sol";

/// @title  SafeCorporateSweepModule
/// @author Zero-Balance Sweep contributors
/// @notice Zodiac-style Safe Module that turns a Gnosis Safe into a programmable
///         corporate sweep account. Idle USDC above an operating threshold is
///         routed to Aave V3, and a Just-In-Time (JIT) withdrawal entrypoint
///         tops the Safe up moments before an outgoing payment.
///
/// @dev    SECURITY MODEL
///         --------------
///         * Normal treasury flows execute through `execTransactionFromModule`
///           on the Safe, which remains the owner of every Aave position.
///           Safe-only recovery functions return assets sent to the module by mistake.
///         * Admin functions (`setThreshold`, `setRelayer`, `manualSupply`,
///           `manualWithdraw`) are gated by `onlySafe`. Safe owners and any other
///           enabled Safe module can make the Safe call these functions.
///         * Automation entrypoints (`executeSweep`, `jitWithdraw`) are gated
///           by an authorized-relayer allowlist; the Safe itself is implicitly
///           authorized.
///         * Only `Enum.Operation.Call` is ever used. The module never asks the
///           Safe to delegatecall, eliminating the worst-case storage-corruption
///           class for module bugs.
///
///         GAS NOTES
///         ---------
///         * `SAFE_ADDRESS`, `ASSET`, `A_TOKEN`, `YIELD_TARGET` are immutable.
///         * `operatingThreshold` is a single SLOAD per call.
///         * Custom errors avoid revert string costs.
///         * A non-zero pre-existing Pool allowance is cleared before each supply.
///           Aave then consumes the exact newly approved amount.
contract SafeCorporateSweepModule is ISafeCorporateSweepModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Immutable wiring
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable SAFE_ADDRESS;
    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable ASSET;
    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable A_TOKEN;
    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable YIELD_TARGET;

    // -----------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    uint256 public operatingThreshold;

    /// @notice Authorized automation relayers (e.g. Gelato dedicated msg.sender).
    mapping(address => bool) private _relayers;

    /// @inheritdoc ISafeCorporateSweepModule
    uint256 public maxJitWithdrawPerCall;
    /// @inheritdoc ISafeCorporateSweepModule
    uint256 public maxSweepPerCall;
    /// @inheritdoc ISafeCorporateSweepModule
    uint256 public relayerCooldown;
    /// @inheritdoc ISafeCorporateSweepModule
    uint256 public lastRelayerActionAt;

    uint256 private _jitIntentNonce;
    uint256 private _jitIntentAmount;
    uint256 private _jitIntentDeadline;
    bool private _jitIntentActive;

    uint256 private _reservedJitBalance;
    uint256 private _jitReservationDeadline;
    bool private _jitReservationActive;

    // -----------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------

    /// @dev Restricts caller to the Safe itself. This includes owner-authorized
    ///      Safe transactions and calls initiated by another enabled Safe module.
    modifier onlySafe() {
        _onlySafe();
        _;
    }

    /// @dev Allows either the Safe (admin override) or any allow-listed relayer.
    modifier onlyRelayerOrSafe() {
        _onlyRelayerOrSafe();
        _;
    }

    function _onlySafe() internal view {
        if (msg.sender != SAFE_ADDRESS) revert NotSafe();
    }

    function _onlyRelayerOrSafe() internal view {
        if (msg.sender != SAFE_ADDRESS && !_relayers[msg.sender]) {
            revert NotAuthorizedRelayer();
        }
    }

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    /// @param _safe              The Safe this module will be enabled on.
    /// @param _asset             Underlying stablecoin (e.g. USDC).
    /// @param _aToken            Aave V3 aToken matching `_asset` (e.g. aUSDC).
    /// @param _yieldTarget       Aave V3 Pool address.
    /// @param _initialThreshold  Minimum operating balance to retain on the Safe.
    /// @param _initialRelayer    Initial automation relayer (pass address(0) to skip).
    constructor(
        address _safe,
        address _asset,
        address _aToken,
        address _yieldTarget,
        uint256 _initialThreshold,
        address _initialRelayer
    ) {
        if (
            _safe == address(0) || _asset == address(0) || _aToken == address(0) || _yieldTarget == address(0)
        ) {
            revert ZeroAddress();
        }
        if (
            _safe.code.length == 0 || _asset.code.length == 0 || _aToken.code.length == 0
                || _yieldTarget.code.length == 0
        ) {
            revert NotContract();
        }
        // Defensive: ensure the published aToken configuration matches `_asset`.
        if (IAToken(_aToken).UNDERLYING_ASSET_ADDRESS() != _asset) {
            revert UnderlyingMismatch();
        }
        // Bind the aToken to the exact Aave pool used for supply and withdrawal.
        // Checking only the underlying permits a deployment typo to publish the
        // wrong receipt-token configuration for the Safe's Aave position.
        if (IAToken(_aToken).POOL() != _yieldTarget) {
            revert PoolMismatch();
        }
        // The Pool is authoritative. A look-alike token can self-report the
        // expected Pool and underlying while not being the registered reserve token.
        if (IAaveV3Pool(_yieldTarget).getReserveData(_asset).aTokenAddress != _aToken) {
            revert PoolMismatch();
        }

        SAFE_ADDRESS = _safe;
        ASSET = _asset;
        A_TOKEN = _aToken;
        YIELD_TARGET = _yieldTarget;
        operatingThreshold = _initialThreshold;

        emit ThresholdUpdated(0, _initialThreshold);

        if (_initialRelayer != address(0)) {
            _relayers[_initialRelayer] = true;
            emit RelayerUpdated(_initialRelayer, true);
        }
    }

    // -----------------------------------------------------------------
    // Admin (Safe-only)
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    function setThreshold(uint256 _amount) external onlySafe {
        uint256 old = operatingThreshold;
        operatingThreshold = _amount;
        emit ThresholdUpdated(old, _amount);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function setRelayer(address _relayer, bool _authorized) external onlySafe {
        if (_relayer == address(0)) revert ZeroAddress();
        _relayers[_relayer] = _authorized;
        emit RelayerUpdated(_relayer, _authorized);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function setJitIntent(uint256 _amount, uint256 _deadline) external onlySafe {
        if (_amount == 0) revert ZeroAmount();
        if (_deadline < block.timestamp) revert JitIntentExpired();

        if (hasActiveJitReservation()) revert JitReservationActive();
        // Clear expired storage without emitting a late release event.
        _clearJitReservation();

        unchecked {
            // safe: monotonic uint256 counter for realistic module lifetime.
            _jitIntentNonce++;
        }
        _jitIntentAmount = _amount;
        _jitIntentDeadline = _deadline;
        _jitIntentActive = true;

        emit JitIntentSet(_jitIntentNonce, _amount, _deadline);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function cancelJitIntent() external onlySafe {
        if (_jitIntentActive) {
            uint256 nonce = _jitIntentNonce;
            _clearJitIntent();
            emit JitIntentCancelled(nonce);
        }
        _clearJitReservation();
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function setRelayerGuardrails(
        uint256 _maxJitWithdrawPerCall,
        uint256 _maxSweepPerCall,
        uint256 _relayerCooldown
    ) external onlySafe {
        maxJitWithdrawPerCall = _maxJitWithdrawPerCall;
        maxSweepPerCall = _maxSweepPerCall;
        relayerCooldown = _relayerCooldown;

        emit RelayerGuardrailsUpdated(_maxJitWithdrawPerCall, _maxSweepPerCall, _relayerCooldown);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function manualSupply(uint256 _amount) external onlySafe nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        _supplyToAave(_amount);
        emit ManualSupplied(_amount);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function manualWithdraw(uint256 _amount) external onlySafe nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        uint256 balanceBefore = IERC20(ASSET).balanceOf(SAFE_ADDRESS);
        _withdrawFromAave(_amount);
        uint256 actualWithdrawn = IERC20(ASSET).balanceOf(SAFE_ADDRESS) - balanceBefore;
        emit ManualWithdrawn(actualWithdrawn);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function recoverToken(address _token, uint256 _amount) external onlySafe nonReentrant {
        if (_token == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();

        IERC20(_token).safeTransfer(SAFE_ADDRESS, _amount);
        emit TokenRecovered(_token, _amount);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function recoverNative() external onlySafe nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();

        (bool success,) = payable(SAFE_ADDRESS).call{value: amount}("");
        if (!success) revert NativeRecoveryFailed();
        emit NativeRecovered(amount);
    }

    // -----------------------------------------------------------------
    // Automation
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    function executeSweep() external onlyRelayerOrSafe nonReentrant returns (uint256 supplied) {
        uint256 threshold = _minimumIdleBalance();
        uint256 balance = IERC20(ASSET).balanceOf(SAFE_ADDRESS);
        if (balance <= threshold) revert NoSweepRequired();

        unchecked {
            // safe: balance > threshold checked above.
            supplied = balance - threshold;
        }

        bool relayerCall = msg.sender != SAFE_ADDRESS;
        if (relayerCall) {
            uint256 cap = maxSweepPerCall;
            if (cap != 0 && supplied > cap) supplied = cap;
            _enforceRelayerGuardrails(supplied, true);
        }

        _supplyToAave(supplied);

        if (relayerCall) _markRelayerAction();

        emit Swept(msg.sender, supplied, IERC20(ASSET).balanceOf(SAFE_ADDRESS));
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function jitWithdraw(uint256 _txAmount)
        external
        onlyRelayerOrSafe
        nonReentrant
        returns (uint256 shortfall)
    {
        if (_txAmount == 0) revert ZeroAmount();

        uint256 balance = IERC20(ASSET).balanceOf(SAFE_ADDRESS);
        if (balance >= _txAmount) revert NoShortfall();

        unchecked {
            // safe: balance < _txAmount checked above.
            shortfall = _txAmount - balance;
        }

        bool relayerCall = msg.sender != SAFE_ADDRESS;
        if (relayerCall) {
            _enforcePendingJitIntent(_txAmount);
            _enforceRelayerGuardrails(shortfall, false);
        }

        uint256 beforeWithdraw = balance;
        _withdrawFromAave(shortfall);
        uint256 afterWithdraw = IERC20(ASSET).balanceOf(SAFE_ADDRESS);
        if (afterWithdraw < _txAmount) revert InsufficientPostWithdrawBalance();

        if (relayerCall) {
            uint256 nonce = _jitIntentNonce;
            uint256 deadline = _jitIntentDeadline;
            _clearJitIntent();
            _reservedJitBalance = _txAmount;
            _jitReservationDeadline = deadline;
            _jitReservationActive = true;
            _markRelayerAction();
            emit JitBalanceReserved(nonce, _txAmount, deadline);
        }

        shortfall = afterWithdraw - beforeWithdraw;
        emit JitWithdrawn(msg.sender, shortfall, _txAmount);
    }

    // -----------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    function isRelayer(address account) external view returns (bool) {
        return _relayers[account];
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function jitIntentNonce() external view returns (uint256) {
        return _jitIntentNonce;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function jitIntentAmount() external view returns (uint256) {
        return _jitIntentAmount;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function jitIntentDeadline() external view returns (uint256) {
        return _jitIntentDeadline;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function hasPendingJitIntent() external view returns (bool) {
        return _jitIntentActive;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function reservedJitBalance() public view returns (uint256) {
        return hasActiveJitReservation() ? _reservedJitBalance : 0;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function jitReservationDeadline() public view returns (uint256) {
        return hasActiveJitReservation() ? _jitReservationDeadline : 0;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function hasActiveJitReservation() public view returns (bool) {
        return _jitReservationActive && block.timestamp <= _jitReservationDeadline;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function previewSweepAmount() external view returns (uint256 supplied) {
        uint256 balance = IERC20(ASSET).balanceOf(SAFE_ADDRESS);
        uint256 threshold = _minimumIdleBalance();
        supplied = balance > threshold ? balance - threshold : 0;

        uint256 cap = maxSweepPerCall;
        if (cap != 0 && supplied > cap) supplied = cap;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function previewShortfall(uint256 _txAmount) external view returns (uint256) {
        uint256 balance = IERC20(ASSET).balanceOf(SAFE_ADDRESS);
        return _txAmount > balance ? _txAmount - balance : 0;
    }

    // -----------------------------------------------------------------
    // Internal: Safe-routed Aave interactions
    // -----------------------------------------------------------------

    /// @dev Supplies `amount` of underlying into Aave V3 with the Safe as the
    ///      `onBehalfOf` recipient of aTokens. The Safe — not the module —
    ///      owns the position end-to-end.
    ///
    ///      Allowance hygiene: clear a pre-existing non-zero Pool allowance for
    ///      strict-approval tokens, then approve exactly `amount`. Aave V3's
    ///      `supply` consumes that allowance. Any failure reverts atomically.
    function _supplyToAave(uint256 amount) internal {
        if (IERC20(ASSET).allowance(SAFE_ADDRESS, YIELD_TARGET) != 0) {
            _execTokenCallFromModule(abi.encodeCall(IERC20.approve, (YIELD_TARGET, 0)));
        }
        _execTokenCallFromModule(abi.encodeCall(IERC20.approve, (YIELD_TARGET, amount)));

        _execFromModule(YIELD_TARGET, 0, abi.encodeCall(IAaveV3Pool.supply, (ASSET, amount, SAFE_ADDRESS, 0)));
    }

    /// @dev Withdraws `amount` of underlying from Aave V3 back to the Safe.
    ///      `msg.sender` from Aave's perspective is the Safe, which is the
    ///      aToken holder.
    function _withdrawFromAave(uint256 amount) internal {
        _execFromModule(YIELD_TARGET, 0, abi.encodeCall(IAaveV3Pool.withdraw, (ASSET, amount, SAFE_ADDRESS)));
    }

    /// @dev Tightly-typed wrapper around `execTransactionFromModule`. Always uses
    ///      `Enum.Operation.Call`; this module never delegatecalls through the Safe.
    function _execFromModule(address to, uint256 value, bytes memory data) internal {
        bool success = ISafe(SAFE_ADDRESS).execTransactionFromModule(to, value, data, Enum.Operation.Call);
        if (!success) revert SafeCallReverted();
    }

    /// @dev Safe-routed token call that accepts no-return ERC-20s and requires
    ///      an explicit true value when return data is present.
    function _execTokenCallFromModule(bytes memory data) internal {
        (bool success, bytes memory returnData) =
            ISafe(SAFE_ADDRESS).execTransactionFromModuleReturnData(ASSET, 0, data, Enum.Operation.Call);
        if (!success) revert SafeCallReverted();
        if (returnData.length != 0) {
            if (returnData.length != 32 || !abi.decode(returnData, (bool))) revert TokenCallFailed();
        }
    }

    function _enforceRelayerGuardrails(uint256 amount, bool isSweep) internal view {
        uint256 lastAction = lastRelayerActionAt;
        uint256 cooldown = relayerCooldown;
        // Subtraction avoids `lastAction + cooldown` overflowing. `lastAction`
        // is a past block timestamp, so it cannot be greater than `block.timestamp`.
        if (cooldown != 0 && lastAction != 0 && block.timestamp - lastAction < cooldown) {
            revert RelayerCooldownActive();
        }

        if (isSweep) {
            uint256 cap = maxSweepPerCall;
            if (cap != 0 && amount > cap) revert SweepCapExceeded();
        } else {
            uint256 cap = maxJitWithdrawPerCall;
            if (cap != 0 && amount > cap) revert JitCapExceeded();
        }
    }

    function _markRelayerAction() internal {
        lastRelayerActionAt = block.timestamp;
    }

    function _clearJitIntent() internal {
        _jitIntentActive = false;
        _jitIntentAmount = 0;
        _jitIntentDeadline = 0;
    }

    function _clearJitReservation() internal {
        if (!_jitReservationActive) return;

        bool wasEffective = block.timestamp <= _jitReservationDeadline;
        _jitReservationActive = false;
        _reservedJitBalance = 0;
        _jitReservationDeadline = 0;
        if (wasEffective) emit JitReservationCleared(_jitIntentNonce);
    }

    function _minimumIdleBalance() internal view returns (uint256 minimum) {
        minimum = operatingThreshold;
        if (hasActiveJitReservation() && _reservedJitBalance > minimum) {
            minimum = _reservedJitBalance;
        }
    }

    function _enforcePendingJitIntent(uint256 txAmount) internal view {
        if (!_jitIntentActive) revert NoPendingJitIntent();
        if (block.timestamp > _jitIntentDeadline) revert JitIntentExpired();
        if (_jitIntentAmount != txAmount) revert JitIntentAmountMismatch();
    }
}
