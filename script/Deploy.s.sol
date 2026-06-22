// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {Strategy} from "../src/Strategy.sol";
import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

contract Deploy is Script {
    // Mainnet WETH
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        // ---- SET THESE BEFORE DEPLOYING ----
        address management = address(0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7);
        address keeper = address(0x604e586F17cE106B64185A7a0d2c1Da5bAce711E);
        address emergencyAdmin = address(0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7);
        address performanceFeeRecipient = address(0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69);
        string memory name = "stETH Accumulator";
        // ------------------------------------

        vm.startBroadcast();

        IStrategyInterface strategy = IStrategyInterface(
            address(new Strategy(WETH, name))
        );

        strategy.setPendingManagement(management);
        strategy.setKeeper(keeper);
        strategy.setEmergencyAdmin(emergencyAdmin);
        strategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        vm.stopBroadcast();

        console2.log("Strategy deployed at:", address(strategy));
        console2.log("  asset:          ", WETH);
        console2.log("  name:           ", name);
        console2.log("  management:     ", management);
        console2.log("  keeper:         ", keeper);
        console2.log("  emergencyAdmin: ", emergencyAdmin);
        console2.log("  perfFeeRecip:   ", performanceFeeRecipient);
        console2.log("");
        console2.log("NOTE: management must call acceptManagement() to finalize ownership transfer.");
    }
}
