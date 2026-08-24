// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {SafeCorporateSweepModule} from "../src/SafeCorporateSweepModule.sol";

/// @notice Deploys the sweep module against a pre-existing Safe.
/// @dev    The Safe still has to enable the module via a separate
///         owner-signed `enableModule(address)` transaction. We don't attempt
///         that here because the deployer EOA isn't a Safe signer.
///
///         Required env:
///             SAFE_ADDRESS         — the Safe to bind the module to.
///             ASSET                — underlying stablecoin (e.g. USDC).
///             ATOKEN               — Aave V3 aToken (e.g. aUSDC).
///             AAVE_POOL            — Aave V3 Pool address.
///             OPERATING_THRESHOLD  — minimum idle balance (in token decimals).
///             RELAYER              — initial automation relayer (or 0x0 to skip).
contract Deploy is Script {
    function run() external returns (SafeCorporateSweepModule module) {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address asset = vm.envAddress("ASSET");
        address aToken = vm.envAddress("ATOKEN");
        address aavePool = vm.envAddress("AAVE_POOL");
        uint256 threshold = vm.envUint("OPERATING_THRESHOLD");
        address relayer = vm.envOr("RELAYER", address(0));

        vm.startBroadcast();
        module = new SafeCorporateSweepModule(safe, asset, aToken, aavePool, threshold, relayer);
        vm.stopBroadcast();

        console2.log("SafeCorporateSweepModule deployed at:", address(module));
        console2.log("Next step: have the Safe call enableModule(", address(module), ")");
    }
}
