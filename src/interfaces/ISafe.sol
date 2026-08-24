// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Operation type used by the Safe when executing a module transaction.
///         `Call` is the standard message call. `DelegateCall` mutates the Safe's
///         own storage and MUST NOT be used for token / Aave interactions.
library Enum {
    enum Operation {
        Call,
        DelegateCall
    }
}

/// @title  ISafe
/// @notice Minimal Gnosis Safe surface required by the Zero-Balance Sweep Module.
/// @dev    The Safe is the asset custodian. Normal treasury operations route
///         through `execTransactionFromModule` so the Safe remains the
///         `msg.sender` against ERC-20s and Aave.
interface ISafe {
    /// @notice Executes a transaction from a previously enabled module.
    /// @param  to        Destination contract.
    /// @param  value     Native value forwarded with the call.
    /// @param  data      ABI-encoded calldata.
    /// @param  operation `Call` (0) or `DelegateCall` (1).
    /// @return success   True if the inner call succeeded.
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) external returns (bool success);

    /// @notice Returns whether `module` is currently enabled on the Safe.
    function isModuleEnabled(address module) external view returns (bool);

    /// @notice Adds `module` to the linked list of enabled modules.
    /// @dev    May only be invoked by the Safe itself (i.e. via a Safe owner tx).
    function enableModule(address module) external;
}
