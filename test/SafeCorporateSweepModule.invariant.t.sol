// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {SafeCorporateSweepModule} from "../src/SafeCorporateSweepModule.sol";
import {MockSafe} from "./mocks/MockSafe.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAaveV3Pool, MockAToken} from "./mocks/MockAaveV3Pool.sol";

contract SweepHandler is Test {
    MockSafe internal immutable safe;
    MockERC20 internal immutable asset;
    MockAToken internal immutable aToken;
    SafeCorporateSweepModule internal immutable module;
    address internal immutable relayer;
    uint256 internal immutable initialFunding;

    constructor(
        MockSafe safe_,
        MockERC20 asset_,
        MockAToken aToken_,
        SafeCorporateSweepModule module_,
        address relayer_,
        uint256 initialFunding_
    ) {
        safe = safe_;
        asset = asset_;
        aToken = aToken_;
        module = module_;
        relayer = relayer_;
        initialFunding = initialFunding_;
    }

    function sweep() external {
        vm.prank(relayer);
        try module.executeSweep() {} catch {}
    }

    function jitWithdraw(uint256 targetSeed) external {
        uint256 idleBalance = asset.balanceOf(address(safe));
        if (idleBalance == initialFunding) return;

        uint256 target = bound(targetSeed, idleBalance + 1, initialFunding);
        vm.prank(address(safe));
        module.cancelJitIntent();
        vm.prank(address(safe));
        module.setJitIntent(target, block.timestamp + 1 days);

        vm.prank(relayer);
        try module.jitWithdraw(target) {} catch {}
    }
}

contract SafeCorporateSweepModuleInvariantTest is StdInvariant, Test {
    uint256 internal constant THRESHOLD = 50_000e6;
    uint256 internal constant FUNDING = 200_000e6;

    MockSafe internal safe;
    MockERC20 internal asset;
    MockAToken internal aToken;
    SafeCorporateSweepModule internal module;
    SweepHandler internal handler;

    function setUp() public {
        address relayer = makeAddr("relayer");
        safe = new MockSafe();
        asset = new MockERC20();
        MockAaveV3Pool pool = new MockAaveV3Pool(address(asset));
        aToken = pool.aToken();
        module = new SafeCorporateSweepModule(
            address(safe), address(asset), address(aToken), address(pool), THRESHOLD, relayer
        );
        safe.enableModule(address(module));
        asset.mint(address(safe), FUNDING);

        handler = new SweepHandler(safe, asset, aToken, module, relayer, FUNDING);
        targetContract(address(handler));
    }

    function invariant_ModuleNeverCustodiesTreasuryAssets() public view {
        assertEq(asset.balanceOf(address(module)), 0, "module underlying balance");
        assertEq(aToken.balanceOf(address(module)), 0, "module aToken balance");
    }

    function invariant_TreasuryPrincipalIsConserved() public view {
        assertEq(
            asset.balanceOf(address(safe)) + aToken.balanceOf(address(safe)),
            FUNDING,
            "principal conservation"
        );
    }

    function invariant_IdleBalanceNeverFallsBelowThreshold() public view {
        assertGe(asset.balanceOf(address(safe)), THRESHOLD, "operating threshold");
    }
}
