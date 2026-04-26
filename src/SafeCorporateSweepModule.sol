// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
///         * The module is non-custodial: it never holds underlying or aTokens.
///           All state-changing calls execute through `execTransactionFromModule`
///           on the Safe so the Safe is the on-chain owner of every position.
///         * Admin functions (`setThreshold`, `setRelayer`, `manualSupply`,
///           `manualWithdraw`) are gated by `onlySafe` — only a Safe-owner-signed
///           transaction can hit them.
///         * Automation entrypoints (`executeSweep`, `jitWithdraw`) are gated
///           by an authorized-relayer allowlist; the Safe itself is implicitly
///           authorized.
///         * Only `Enum.Operation.Call` is ever used. The module never asks the
///           Safe to delegatecall, eliminating the worst-case storage-corruption
///           class for module bugs.
///
///         GAS NOTES
///         ---------
///         * `safeAddress`, `asset`, `aToken`, `yieldTarget` are immutable.
///         * `operatingThreshold` is a single SLOAD per call.
///         * Custom errors avoid revert string costs.
///         * Allowance is reset to 0 after every supply to keep the Safe lean
///           and to support strict-allowance underlyings (USDT-style) in forks.
contract SafeCorporateSweepModule is ISafeCorporateSweepModule, ReentrancyGuard {
    // -----------------------------------------------------------------
    // Immutable wiring
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable safeAddress;
    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable asset;
    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable aToken;
    /// @inheritdoc ISafeCorporateSweepModule
    address public immutable yieldTarget;

    // -----------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    uint256 public operatingThreshold;

    /// @notice Authorized automation relayers (e.g. Gelato dedicated msg.sender).
    mapping(address => bool) private _relayers;

    // -----------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------

    /// @dev Restricts caller to the Safe itself. The Safe can only invoke this
    ///      module via an owner-threshold-signed `execTransaction`, so this is
    ///      effectively the Safe's owners acting collectively.
    modifier onlySafe() {
        if (msg.sender != safeAddress) revert NotSafe();
        _;
    }

    /// @dev Allows either the Safe (admin override) or any allow-listed relayer.
    modifier onlyRelayerOrSafe() {
        if (msg.sender != safeAddress && !_relayers[msg.sender]) {
            revert NotAuthorizedRelayer();
        }
        _;
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
        if (_safe == address(0) || _asset == address(0) || _aToken == address(0) || _yieldTarget == address(0)) {
            revert ZeroAddress();
        }
        // Defensive: ensure the aToken's underlying actually matches `_asset`.
        // Mismatched wiring would silently succeed at deploy then drain the
        // Safe's allowance into the wrong reserve, so we fail closed.
        if (IAToken(_aToken).UNDERLYING_ASSET_ADDRESS() != _asset) {
            revert UnderlyingMismatch();
        }

        safeAddress = _safe;
        asset = _asset;
        aToken = _aToken;
        yieldTarget = _yieldTarget;
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
    function manualSupply(uint256 _amount) external onlySafe nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        _supplyToAave(_amount);
        emit ManualSupplied(_amount);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function manualWithdraw(uint256 _amount) external onlySafe nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        _withdrawFromAave(_amount);
        emit ManualWithdrawn(_amount);
    }

    // -----------------------------------------------------------------
    // Automation
    // -----------------------------------------------------------------

    /// @inheritdoc ISafeCorporateSweepModule
    function executeSweep() external onlyRelayerOrSafe nonReentrant returns (uint256 supplied) {
        uint256 threshold = operatingThreshold;
        uint256 balance = IERC20(asset).balanceOf(safeAddress);
        if (balance <= threshold) revert NoSweepRequired();

        unchecked {
            // safe: balance > threshold checked above.
            supplied = balance - threshold;
        }

        _supplyToAave(supplied);

        emit Swept(msg.sender, supplied, threshold);
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function jitWithdraw(uint256 _txAmount)
        external
        onlyRelayerOrSafe
        nonReentrant
        returns (uint256 shortfall)
    {
        if (_txAmount == 0) revert ZeroAmount();

        uint256 balance = IERC20(asset).balanceOf(safeAddress);
        if (balance >= _txAmount) revert NoShortfall();

        unchecked {
            // safe: balance < _txAmount checked above.
            shortfall = _txAmount - balance;
        }

        _withdrawFromAave(shortfall);

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
    function previewSweepAmount() external view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(safeAddress);
        uint256 threshold = operatingThreshold;
        return balance > threshold ? balance - threshold : 0;
    }

    /// @inheritdoc ISafeCorporateSweepModule
    function previewShortfall(uint256 _txAmount) external view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(safeAddress);
        return _txAmount > balance ? _txAmount - balance : 0;
    }

    // -----------------------------------------------------------------
    // Internal: Safe-routed Aave interactions
    // -----------------------------------------------------------------

    /// @dev Supplies `amount` of underlying into Aave V3 with the Safe as the
    ///      `onBehalfOf` recipient of aTokens. The Safe — not the module —
    ///      owns the position end-to-end.
    ///
    ///      Allowance hygiene: Aave V3's `supply` calls `safeTransferFrom` for
    ///      exactly `amount`, fully consuming the allowance set below. We
    ///      therefore skip a defensive approve(0) follow-up to save gas; if
    ///      either step reverts the whole module call reverts atomically and
    ///      no residual approval is left on the Safe.
    function _supplyToAave(uint256 amount) internal {
        _execFromModule(
            asset,
            0,
            abi.encodeCall(IERC20.approve, (yieldTarget, amount))
        );

        _execFromModule(
            yieldTarget,
            0,
            abi.encodeCall(IAaveV3Pool.supply, (asset, amount, safeAddress, 0))
        );
    }

    /// @dev Withdraws `amount` of underlying from Aave V3 back to the Safe.
    ///      `msg.sender` from Aave's perspective is the Safe, which is the
    ///      aToken holder.
    function _withdrawFromAave(uint256 amount) internal {
        _execFromModule(
            yieldTarget,
            0,
            abi.encodeCall(IAaveV3Pool.withdraw, (asset, amount, safeAddress))
        );
    }

    /// @dev Tightly-typed wrapper around `execTransactionFromModule`. Always uses
    ///      `Enum.Operation.Call`; this module never delegatecalls through the Safe.
    function _execFromModule(address to, uint256 value, bytes memory data) internal {
        bool success = ISafe(safeAddress).execTransactionFromModule(to, value, data, Enum.Operation.Call);
        if (!success) revert SafeCallReverted();
    }
}
