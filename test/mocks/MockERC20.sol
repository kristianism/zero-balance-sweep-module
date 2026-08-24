// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Models tokens that reject non-zero-to-non-zero allowance changes.
contract MockStrictApprovalERC20 is MockERC20 {
    function approve(address spender, uint256 amount) public override returns (bool) {
        require(amount == 0 || allowance(msg.sender, spender) == 0, "reset allowance first");
        return super.approve(spender, amount);
    }
}
