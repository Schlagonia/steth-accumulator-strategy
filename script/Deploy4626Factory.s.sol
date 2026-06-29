// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {Strategy4626Factory} from "../src/Strategy4626Factory.sol";

contract Deploy4626Factory is Script {
    function run() external {
        address management = address(0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271);
        address performanceFeeRecipient = address(0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69);
        address keeper = address(0x604e586F17cE106B64185A7a0d2c1Da5bAce711E);
        address emergencyAdmin = address(0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271);
        address asset = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

        vm.startBroadcast();

        Strategy4626Factory factory =
            new Strategy4626Factory(management, performanceFeeRecipient, keeper, emergencyAdmin, asset);

        vm.stopBroadcast();

        console2.log("Strategy4626Factory deployed at:", address(factory));
        console2.log("  management:     ", management);
        console2.log("  keeper:         ", keeper);
        console2.log("  emergencyAdmin: ", emergencyAdmin);
        console2.log("  perfFeeRecip:   ", performanceFeeRecipient);
        console2.log("  asset:          ", asset);
    }
}
