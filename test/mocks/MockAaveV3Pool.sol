// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAaveV3Pool, IAToken} from "../../src/interfaces/IAaveV3Pool.sol";

contract MockAToken is IAToken {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public immutable POOL;

    mapping(address => uint256) private _balances;

    constructor(address asset, address pool) {
        UNDERLYING_ASSET_ADDRESS = asset;
        POOL = pool;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == POOL, "only pool");
        _balances[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == POOL, "only pool");
        _balances[from] -= amount;
    }
}

contract MockAaveV3Pool is IAaveV3Pool {
    IERC20 public immutable asset;
    MockAToken public immutable aToken;

    constructor(address asset_) {
        asset = IERC20(asset_);
        aToken = new MockAToken(asset_, address(this));
    }

    function supply(address suppliedAsset, uint256 amount, address onBehalfOf, uint16) external {
        require(suppliedAsset == address(asset), "asset");
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address withdrawnAsset, uint256 amount, address to)
        external
        returns (uint256 withdrawn)
    {
        require(withdrawnAsset == address(asset), "asset");
        uint256 balance = aToken.balanceOf(msg.sender);
        withdrawn = amount == type(uint256).max ? balance : amount;
        aToken.burn(msg.sender, withdrawn);
        require(asset.transfer(to, withdrawn), "transfer");
    }
}
