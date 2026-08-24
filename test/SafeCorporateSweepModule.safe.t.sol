// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeCorporateSweepModule} from "../src/SafeCorporateSweepModule.sol";
import {ISafe} from "../src/interfaces/ISafe.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafeSetup {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

/// @notice Fork test against an official Safe v1.4.1 proxy and Aave V3.
contract SafeCorporateSweepModuleSafeIntegrationTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant AUSDC_V3 = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant SAFE_SINGLETON_V141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_PROXY_FACTORY_V141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;

    uint256 internal constant THRESHOLD = 50_000e6;
    uint256 internal constant FUNDING = 200_000e6;

    address internal safe;
    address internal owner = makeAddr("safe-owner");
    address internal relayer = makeAddr("relayer");
    SafeCorporateSweepModule internal module;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length != 0) vm.createSelectFork(rpc);
        if (SAFE_PROXY_FACTORY_V141.code.length == 0) vm.skip(true);

        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory initializer = abi.encodeCall(
            ISafeSetup.setup,
            (owners, 1, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactory(SAFE_PROXY_FACTORY_V141)
            .createProxyWithNonce(SAFE_SINGLETON_V141, initializer, 20260825);

        module = new SafeCorporateSweepModule(safe, USDC, AUSDC_V3, AAVE_POOL, THRESHOLD, relayer);

        // Safe's `authorized` modifier requires a self-call. Pranking the Safe
        // models the final call made by an owner-approved Safe transaction.
        vm.prank(safe);
        ISafe(safe).enableModule(address(module));
        deal(USDC, safe, FUNDING);
    }

    function test_RealSafeProxySweepAndJitWithdrawal() public {
        assertTrue(ISafe(safe).isModuleEnabled(address(module)));

        vm.prank(relayer);
        module.executeSweep();
        assertEq(IERC20(USDC).balanceOf(safe), THRESHOLD);

        uint256 outgoingAmount = 80_000e6;
        vm.prank(safe);
        module.setJitIntent(outgoingAmount, block.timestamp + 1 hours);
        vm.prank(relayer);
        module.jitWithdraw(outgoingAmount);

        assertEq(IERC20(USDC).balanceOf(safe), outgoingAmount);
    }
}
