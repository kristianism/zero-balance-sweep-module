// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SafeCorporateSweepModule} from "../src/SafeCorporateSweepModule.sol";
import {ISafeCorporateSweepModule} from "../src/interfaces/ISafeCorporateSweepModule.sol";
import {MockSafe} from "./mocks/MockSafe.sol";
import {
    MockERC20,
    MockFalseApprovalERC20,
    MockNoReturnERC20,
    MockStrictApprovalERC20
} from "./mocks/MockERC20.sol";
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

    function test_ConstructorRejectsUnregisteredLookalikeAToken() public {
        MockAToken lookalikeAToken = new MockAToken(address(asset), address(pool));

        vm.expectRevert(ISafeCorporateSweepModule.PoolMismatch.selector);
        new SafeCorporateSweepModule(
            address(safe), address(asset), address(lookalikeAToken), address(pool), THRESHOLD, relayer
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

    function test_SweepResetsPreExistingAllowanceForStrictApprovalToken() public {
        MockSafe localSafe = new MockSafe();
        MockStrictApprovalERC20 strictAsset = new MockStrictApprovalERC20();
        MockAaveV3Pool localPool = new MockAaveV3Pool(address(strictAsset));
        SafeCorporateSweepModule localModule = new SafeCorporateSweepModule(
            address(localSafe),
            address(strictAsset),
            address(localPool.aToken()),
            address(localPool),
            THRESHOLD,
            relayer
        );
        localSafe.enableModule(address(localModule));
        strictAsset.mint(address(localSafe), FUNDING);

        vm.prank(address(localSafe));
        strictAsset.approve(address(localPool), 1);

        vm.prank(relayer);
        localModule.executeSweep();

        assertEq(strictAsset.balanceOf(address(localSafe)), THRESHOLD);
        assertEq(strictAsset.allowance(address(localSafe), address(localPool)), 0);
    }

    function test_SweepSupportsNoReturnApprovalToken() public {
        MockSafe localSafe = new MockSafe();
        MockNoReturnERC20 noReturnAsset = new MockNoReturnERC20();
        MockAaveV3Pool localPool = new MockAaveV3Pool(address(noReturnAsset));
        SafeCorporateSweepModule localModule = new SafeCorporateSweepModule(
            address(localSafe),
            address(noReturnAsset),
            address(localPool.aToken()),
            address(localPool),
            THRESHOLD,
            relayer
        );
        localSafe.enableModule(address(localModule));
        noReturnAsset.mint(address(localSafe), FUNDING);

        vm.prank(relayer);
        assertEq(localModule.executeSweep(), FUNDING - THRESHOLD);

        assertEq(noReturnAsset.balanceOf(address(localSafe)), THRESHOLD);
        assertEq(localPool.aToken().balanceOf(address(localSafe)), FUNDING - THRESHOLD);
    }

    function test_SweepRejectsFalseReturningApprovalToken() public {
        MockSafe localSafe = new MockSafe();
        MockFalseApprovalERC20 falseReturnAsset = new MockFalseApprovalERC20();
        MockAaveV3Pool localPool = new MockAaveV3Pool(address(falseReturnAsset));
        SafeCorporateSweepModule localModule = new SafeCorporateSweepModule(
            address(localSafe),
            address(falseReturnAsset),
            address(localPool.aToken()),
            address(localPool),
            THRESHOLD,
            relayer
        );
        localSafe.enableModule(address(localModule));
        falseReturnAsset.mint(address(localSafe), FUNDING);
        falseReturnAsset.seedAllowance(address(localSafe), address(localPool), type(uint256).max);

        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.TokenCallFailed.selector);
        localModule.executeSweep();

        assertEq(falseReturnAsset.balanceOf(address(localSafe)), FUNDING);
        assertEq(localPool.aToken().balanceOf(address(localSafe)), 0);
    }

    function test_RelayerSweepClipsToCapInsteadOfBrickingOnDonatedDust() public {
        uint256 cap = FUNDING - THRESHOLD;
        asset.mint(address(safe), 1);
        vm.prank(address(safe));
        module.setRelayerGuardrails(0, cap, 0);
        assertEq(module.previewSweepAmount(), cap);

        vm.prank(relayer);
        uint256 supplied = module.executeSweep();

        assertEq(supplied, cap);
        assertEq(asset.balanceOf(address(safe)), THRESHOLD + 1);
        assertEq(aToken.balanceOf(address(safe)), cap);
    }

    function test_JitFundedBalanceCannotBeResweptBeforeIntentDeadline() public {
        uint256 txAmount = 80_000e6;
        vm.prank(relayer);
        module.executeSweep();

        vm.prank(address(safe));
        module.setJitIntent(txAmount, block.timestamp + 1 days);
        vm.prank(relayer);
        module.jitWithdraw(txAmount);

        vm.prank(relayer);
        vm.expectRevert(ISafeCorporateSweepModule.NoSweepRequired.selector);
        module.executeSweep();

        assertEq(asset.balanceOf(address(safe)), txAmount);
        assertEq(module.reservedJitBalance(), txAmount);
        assertTrue(module.hasActiveJitReservation());

        asset.mint(address(safe), 1);
        vm.prank(relayer);
        assertEq(module.executeSweep(), 1);
        assertEq(asset.balanceOf(address(safe)), txAmount);

        vm.prank(address(safe));
        vm.expectRevert(ISafeCorporateSweepModule.JitReservationActive.selector);
        module.setJitIntent(txAmount + 1, block.timestamp + 2 days);
    }

    function test_JitReservationCanBeReleasedOrExpire() public {
        uint256 txAmount = 80_000e6;
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(relayer);
        module.executeSweep();

        vm.prank(address(safe));
        module.setJitIntent(txAmount, deadline);
        vm.prank(relayer);
        module.jitWithdraw(txAmount);

        vm.prank(address(safe));
        module.cancelJitIntent();
        assertFalse(module.hasActiveJitReservation());
        assertEq(module.reservedJitBalance(), 0);

        vm.prank(relayer);
        assertEq(module.executeSweep(), txAmount - THRESHOLD);

        vm.prank(address(safe));
        module.setJitIntent(txAmount, deadline);
        vm.prank(relayer);
        module.jitWithdraw(txAmount);
        vm.warp(deadline + 1);

        assertFalse(module.hasActiveJitReservation());
        assertEq(module.reservedJitBalance(), 0);
        assertEq(module.jitReservationDeadline(), 0);

        vm.prank(address(safe));
        module.setJitIntent(txAmount + 1, block.timestamp + 1 days);
        assertTrue(module.hasPendingJitIntent());

        vm.prank(relayer);
        assertEq(module.executeSweep(), txAmount - THRESHOLD);
    }

    function test_ManualFullWithdrawEmitsActualAmount() public {
        vm.prank(relayer);
        module.executeSweep();
        uint256 expectedWithdrawn = aToken.balanceOf(address(safe));

        vm.expectEmit(false, false, false, true, address(module));
        emit ISafeCorporateSweepModule.ManualWithdrawn(expectedWithdrawn);
        vm.prank(address(safe));
        module.manualWithdraw(type(uint256).max);

        assertEq(asset.balanceOf(address(safe)), FUNDING);
        assertEq(aToken.balanceOf(address(safe)), 0);
    }

    function test_SafeCanRecoverTokensSentDirectlyToModule() public {
        uint256 amount = 123e6;
        asset.mint(address(module), amount);

        vm.expectEmit(true, false, false, true, address(module));
        emit ISafeCorporateSweepModule.TokenRecovered(address(asset), amount);
        vm.prank(address(safe));
        module.recoverToken(address(asset), amount);

        assertEq(asset.balanceOf(address(module)), 0);
        assertEq(asset.balanceOf(address(safe)), FUNDING + amount);
    }

    function test_SafeCanRecoverForcedNativeCurrency() public {
        uint256 amount = 1 ether;
        uint256 safeBalanceBefore = address(safe).balance;
        vm.deal(address(module), amount);

        vm.expectEmit(false, false, false, true, address(module));
        emit ISafeCorporateSweepModule.NativeRecovered(amount);
        vm.prank(address(safe));
        module.recoverNative();

        assertEq(address(module).balance, 0);
        assertEq(address(safe).balance, safeBalanceBefore + amount);
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
