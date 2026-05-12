// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeCorporateSweepModule} from "../src/SafeCorporateSweepModule.sol";
import {ISafeCorporateSweepModule} from "../src/interfaces/ISafeCorporateSweepModule.sol";
import {IAToken} from "../src/interfaces/IAaveV3Pool.sol";

import {MockSafe} from "./mocks/MockSafe.sol";

/// @title  SafeCorporateSweepModule fork tests
/// @notice Forks Ethereum mainnet so we exercise the module against real Aave V3
///         liquidity and a real USDC reserve.
///
///         Run with:
///             forge test --fork-url $MAINNET_RPC_URL -vv
contract SafeCorporateSweepModuleTest is Test {
    // ---- Mainnet addresses ------------------------------------------------
    address internal constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant AUSDC_V3  = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // ---- Test fixtures ----------------------------------------------------
    MockSafe internal safe;
    SafeCorporateSweepModule internal module;

    address internal relayer  = makeAddr("gelato-relayer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant THRESHOLD     = 50_000e6;   // 50k USDC operating buffer
    uint256 internal constant SAFE_FUNDING  = 200_000e6;  // 200k USDC seeded into the Safe

    function setUp() public {
        // If `--fork-url` wasn't passed but `MAINNET_RPC_URL` is set, spin up
        // the fork programmatically. This lets `forge test` work either way.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length != 0) {
            vm.createSelectFork(rpc);
        }

        // No live fork detected — these tests need real Aave V3 liquidity, so
        // skip silently in non-forking CI lanes rather than fail noisily.
        if (AAVE_POOL.code.length == 0) {
            vm.skip(true);
        }

        safe = new MockSafe();

        module = new SafeCorporateSweepModule({
            _safe:             address(safe),
            _asset:            USDC,
            _aToken:           AUSDC_V3,
            _yieldTarget:      AAVE_POOL,
            _initialThreshold: THRESHOLD,
            _initialRelayer:   relayer
        });

        safe.enableModule(address(module));

        // Seed the Safe with USDC. Foundry's `deal` writes balance directly
        // into the ERC-20 storage slot — no need to impersonate a whale.
        deal(USDC, address(safe), SAFE_FUNDING);
    }

    // -----------------------------------------------------------------
    // Constructor / wiring
    // -----------------------------------------------------------------

    function test_Wiring_Immutables() public view {
        assertEq(module.SAFE_ADDRESS(), address(safe), "safe");
        assertEq(module.ASSET(), USDC, "asset");
        assertEq(module.A_TOKEN(), AUSDC_V3, "aToken");
        assertEq(module.YIELD_TARGET(), AAVE_POOL, "pool");
        assertEq(module.operatingThreshold(), THRESHOLD, "threshold");
        assertTrue(module.isRelayer(relayer), "relayer authorized");
        assertTrue(safe.isModuleEnabled(address(module)), "module enabled");
    }

    function test_Constructor_RevertsOnUnderlyingMismatch() public {
        // aUSDC paired with DAI as `_asset` should fail the underlying check.
        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        vm.expectRevert(ISafeCorporateSweepModule.UnderlyingMismatch.selector);
        new SafeCorporateSweepModule(address(safe), dai, AUSDC_V3, AAVE_POOL, 0, address(0));
    }

    // -----------------------------------------------------------------
    // executeSweep (the headline path)
    // -----------------------------------------------------------------

    function test_ExecuteSweep_RelayerSuppliesDeltaToAave() public {
        uint256 expectedSupply = SAFE_FUNDING - THRESHOLD;

        vm.expectEmit(true, false, false, true, address(module));
        emit ISafeCorporateSweepModule.Swept(relayer, expectedSupply, THRESHOLD);

        vm.prank(relayer);
        uint256 supplied = module.executeSweep();

        assertEq(supplied, expectedSupply, "supplied delta");
        assertEq(IERC20(USDC).balanceOf(address(safe)), THRESHOLD, "safe balance == threshold");

        // aUSDC mints 1:1 at supply time. Allow ±1 wei rounding for index math.
        uint256 aBal = IAToken(AUSDC_V3).balanceOf(address(safe));
        assertApproxEqAbs(aBal, expectedSupply, 1, "aUSDC ~ supplied");

        // Allowance should be left at zero post-sweep.
        assertEq(IERC20(USDC).allowance(address(safe), AAVE_POOL), 0, "allowance reset");
    }

    function test_ExecuteSweep_RevertsWhenBalanceAtOrBelowThreshold() public {
        // Drain the Safe down to the threshold.
        deal(USDC, address(safe), THRESHOLD);
        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.NoSweepRequired.selector);
        module.executeSweep();
    }

    function test_ExecuteSweep_RevertsForUnauthorizedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(ISafeCorporateSweepModule.NotAuthorizedRelayer.selector);
        module.executeSweep();
    }

    // -----------------------------------------------------------------
    // jitWithdraw (the headline path)
    // -----------------------------------------------------------------

    function test_JitWithdraw_TopsUpExactShortfall() public {
        // First sweep so we have an Aave position to draw from.
        vm.prank(relayer);
        module.executeSweep();
        assertEq(IERC20(USDC).balanceOf(address(safe)), THRESHOLD);

        // The treasurer wants to send 80k USDC; the Safe only has 50k idle.
        uint256 outgoingTx   = 80_000e6;
        uint256 expectedPull = outgoingTx - THRESHOLD;

        vm.expectEmit(true, false, false, true, address(module));
        emit ISafeCorporateSweepModule.JitWithdrawn(relayer, expectedPull, outgoingTx);

        vm.prank(address(safe));
        module.setJitIntent(outgoingTx, block.timestamp + 1 hours);

        vm.prank(relayer);
        uint256 pulled = module.jitWithdraw(outgoingTx);

        assertEq(pulled, expectedPull, "pulled exact shortfall");
        assertGe(IERC20(USDC).balanceOf(address(safe)), outgoingTx, "safe funded for tx");
    }

    function test_JitWithdraw_RevertsWhenSafeAlreadyHasEnough() public {
        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.NoShortfall.selector);
        module.jitWithdraw(THRESHOLD); // Safe holds way more than this
    }

    function test_JitWithdraw_RelayerRequiresIntent() public {
        vm.prank(relayer);
        module.executeSweep();

        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.NoPendingJitIntent.selector);
        module.jitWithdraw(80_000e6);
    }

    function test_JitWithdraw_RevertsOnIntentAmountMismatch() public {
        vm.prank(relayer);
        module.executeSweep();

        vm.prank(address(safe));
        module.setJitIntent(81_000e6, block.timestamp + 1 hours);

        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.JitIntentAmountMismatch.selector);
        module.jitWithdraw(80_000e6);
    }

    // -----------------------------------------------------------------
    // Admin paths (Safe-only)
    // -----------------------------------------------------------------

    function test_SetThreshold_OnlySafe() public {
        vm.prank(stranger);
        vm.expectRevert(ISafeCorporateSweepModule.NotSafe.selector);
        module.setThreshold(1);

        vm.prank(address(safe));
        module.setThreshold(123_456);
        assertEq(module.operatingThreshold(), 123_456);
    }

    function test_ManualSupplyAndWithdraw_OnlySafe() public {
        // Stranger blocked
        vm.prank(stranger);
        vm.expectRevert(ISafeCorporateSweepModule.NotSafe.selector);
        module.manualSupply(1e6);

        // Safe pushes 10k into Aave
        vm.prank(address(safe));
        module.manualSupply(10_000e6);
        assertApproxEqAbs(IAToken(AUSDC_V3).balanceOf(address(safe)), 10_000e6, 1);

        // Safe pulls 4k back
        vm.prank(address(safe));
        module.manualWithdraw(4_000e6);
        // Safe USDC balance should rise back by ~4k from where it was after supply.
        assertGe(IERC20(USDC).balanceOf(address(safe)), SAFE_FUNDING - 10_000e6 + 4_000e6 - 1);
    }

    function test_SetRelayer_FlowsAndGates() public {
        address newBot = makeAddr("new-bot");

        // Authorize via Safe
        vm.prank(address(safe));
        module.setRelayer(newBot, true);
        assertTrue(module.isRelayer(newBot));

        // New bot can sweep
        vm.prank(newBot);
        module.executeSweep();

        // Revoke
        vm.prank(address(safe));
        module.setRelayer(newBot, false);
        assertFalse(module.isRelayer(newBot));

        // Reseed + try again — should now revert.
        deal(USDC, address(safe), SAFE_FUNDING);
        vm.prank(newBot);
        vm.expectRevert(ISafeCorporateSweepModule.NotAuthorizedRelayer.selector);
        module.executeSweep();
    }

    function test_SetJitIntent_OnlySafe() public {
        vm.prank(stranger);
        vm.expectRevert(ISafeCorporateSweepModule.NotSafe.selector);
        module.setJitIntent(1e6, block.timestamp + 1 hours);

        vm.prank(address(safe));
        module.setJitIntent(50_000e6, block.timestamp + 1 hours);
        assertTrue(module.hasPendingJitIntent());
        assertEq(module.jitIntentAmount(), 50_000e6);
    }

    function test_RelayerGuardrails_CooldownAndCaps() public {
        vm.prank(address(safe));
        module.setRelayerGuardrails(40_000e6, 120_000e6, 600); // 10 min cooldown

        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.SweepCapExceeded.selector);
        module.executeSweep(); // default sweep is 150k

        vm.prank(address(safe));
        module.setRelayerGuardrails(40_000e6, 200_000e6, 600);

        vm.prank(relayer);
        module.executeSweep();

        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.RelayerCooldownActive.selector);
        module.executeSweep();
    }

    // -----------------------------------------------------------------
    // View helpers
    // -----------------------------------------------------------------

    function test_PreviewHelpersMatchExecution() public {
        uint256 sweepable = module.previewSweepAmount();
        assertEq(sweepable, SAFE_FUNDING - THRESHOLD);

        vm.prank(relayer);
        uint256 supplied = module.executeSweep();
        assertEq(supplied, sweepable);

        uint256 outgoingTx = 75_000e6;
        uint256 shortfall  = module.previewShortfall(outgoingTx);
        assertEq(shortfall, outgoingTx - THRESHOLD);
    }
}
