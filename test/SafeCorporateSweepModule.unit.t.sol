// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SafeCorporateSweepModule} from "../src/SafeCorporateSweepModule.sol";
import {ISafeCorporateSweepModule} from "../src/interfaces/ISafeCorporateSweepModule.sol";
import {MockSafe} from "./mocks/MockSafe.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAaveV3Pool, MockAToken} from "./mocks/MockAaveV3Pool.sol";

contract SafeCorporateSweepModuleUnitTest is Test {
    uint256 internal constant THRESHOLD = 50_000e6;
    uint256 internal constant FUNDING = 200_000e6;

    MockSafe internal safe;
    MockERC20 internal asset;
    MockAaveV3Pool internal pool;
    MockAToken internal aToken;
    SafeCorporateSweepModule internal module;

    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        safe = new MockSafe();
        asset = new MockERC20();
        pool = new MockAaveV3Pool(address(asset));
        aToken = pool.aToken();
        module = new SafeCorporateSweepModule(
            address(safe), address(asset), address(aToken), address(pool), THRESHOLD, relayer
        );
        safe.enableModule(address(module));
        asset.mint(address(safe), FUNDING);
    }

    function test_ConstructorRevertsOnATokenPoolMismatch() public {
        MockAaveV3Pool otherPool = new MockAaveV3Pool(address(asset));

        vm.expectRevert(ISafeCorporateSweepModule.PoolMismatch.selector);
        new SafeCorporateSweepModule(
            address(safe), address(asset), address(aToken), address(otherPool), THRESHOLD, relayer
        );
    }

    function test_AccessControlRejectsUnauthorizedCallers() public {
        vm.prank(stranger);
        vm.expectRevert(ISafeCorporateSweepModule.NotAuthorizedRelayer.selector);
        module.executeSweep();

        vm.prank(stranger);
        vm.expectRevert(ISafeCorporateSweepModule.NotSafe.selector);
        module.setThreshold(1);
    }

    function test_CancelJitIntentBlocksStaleIntentAfterRelayerReauthorization() public {
        vm.prank(relayer);
        module.executeSweep();

        vm.prank(address(safe));
        module.setJitIntent(80_000e6, block.timestamp + 30 days);
        vm.prank(address(safe));
        module.setRelayer(relayer, false);
        vm.prank(address(safe));
        module.cancelJitIntent();
        vm.prank(address(safe));
        module.setRelayer(relayer, true);

        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.NoPendingJitIntent.selector);
        module.jitWithdraw(80_000e6);
    }

    function test_MaxCooldownDoesNotBrickTheFirstRelayerAction() public {
        vm.prank(address(safe));
        module.setRelayerGuardrails(0, 0, type(uint256).max);

        vm.prank(relayer);
        module.executeSweep();

        assertEq(asset.balanceOf(address(safe)), THRESHOLD);
    }

    function testFuzz_ExecuteSweepPreservesThresholdAndConservesAssets(
        uint96 thresholdSeed,
        uint96 excessSeed
    ) public {
        uint256 threshold = bound(uint256(thresholdSeed), 1, 1_000_000e6);
        uint256 excess = bound(uint256(excessSeed), 1, 1_000_000e6);
        uint256 funding = threshold + excess;

        MockSafe localSafe = new MockSafe();
        MockERC20 localAsset = new MockERC20();
        MockAaveV3Pool localPool = new MockAaveV3Pool(address(localAsset));
        SafeCorporateSweepModule localModule = new SafeCorporateSweepModule(
            address(localSafe),
            address(localAsset),
            address(localPool.aToken()),
            address(localPool),
            threshold,
            relayer
        );
        localSafe.enableModule(address(localModule));
        localAsset.mint(address(localSafe), funding);

        vm.prank(relayer);
        uint256 supplied = localModule.executeSweep();

        assertEq(supplied, excess);
        assertEq(localAsset.balanceOf(address(localSafe)), threshold);
        assertEq(localPool.aToken().balanceOf(address(localSafe)), excess);
        assertEq(
            localAsset.balanceOf(address(localSafe)) + localPool.aToken().balanceOf(address(localSafe)),
            funding
        );
        assertEq(localAsset.balanceOf(address(localModule)), 0);
        assertEq(localPool.aToken().balanceOf(address(localModule)), 0);
    }

    function testFuzz_JitWithdrawFillsExactShortfallAndConservesAssets(uint96 txAmountSeed) public {
        vm.prank(relayer);
        module.executeSweep();

        uint256 txAmount = bound(uint256(txAmountSeed), THRESHOLD + 1, FUNDING);
        vm.prank(address(safe));
        module.setJitIntent(txAmount, block.timestamp + 1 days);

        vm.prank(relayer);
        uint256 withdrawn = module.jitWithdraw(txAmount);

        assertEq(withdrawn, txAmount - THRESHOLD);
        assertEq(asset.balanceOf(address(safe)), txAmount);
        assertEq(aToken.balanceOf(address(safe)), FUNDING - txAmount);
        assertEq(asset.balanceOf(address(safe)) + aToken.balanceOf(address(safe)), FUNDING);
        assertEq(asset.balanceOf(address(module)), 0);
        assertEq(aToken.balanceOf(address(module)), 0);
        assertFalse(module.hasPendingJitIntent());
        assertEq(module.jitIntentAmount(), 0);
        assertEq(module.jitIntentDeadline(), 0);
    }
}
