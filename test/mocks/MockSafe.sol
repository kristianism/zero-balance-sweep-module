// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Enum} from "../../src/interfaces/ISafe.sol";

/// @title  MockSafe
/// @notice Minimal stand-in for a Gnosis Safe used in fork tests.
/// @dev    Implements just enough of the Safe API for the sweep module:
///         - `enableModule` adds the module to an allow-list.
///         - `execTransactionFromModule` forwards the call from this contract,
///           making `address(this)` the on-chain `msg.sender` against ERC-20s
///           and Aave, exactly like a real Safe.
///         This mock intentionally has no signature / threshold logic; tests
///         drive admin functions by `vm.prank(address(safe))` to simulate an
///         owner-signed Safe transaction.
contract MockSafe {
    mapping(address => bool) public modules;

    event ModuleEnabled(address indexed module);

    function enableModule(address module) external {
        modules[module] = true;
        emit ModuleEnabled(module);
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return modules[module];
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) external returns (bool success) {
        require(modules[msg.sender], "MockSafe: module not enabled");
        require(operation == Enum.Operation.Call, "MockSafe: only Call supported");

        (success,) = to.call{value: value}(data);
    }

    receive() external payable {}
}
