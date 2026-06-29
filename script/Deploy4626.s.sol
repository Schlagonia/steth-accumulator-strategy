// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {Strategy4626} from "../src/Strategy4626.sol";
import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

contract Deploy4626 is Script {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        address management = address(0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271);
        address vault = address(0xE73b2561309Bed1035D2145275BCA1aEcf85A8F7);
        string memory name = "wstETH/yvUSD Morpho Lender Borrower Convertor";

        vm.startBroadcast();

        IStrategyInterface strategy = IStrategyInterface(address(new Strategy4626(WETH, name, vault)));

        vm.stopBroadcast();

        console2.log("Strategy deployed at:", address(strategy));
        console2.log("  asset:          ", WETH);
        console2.log("  vault:          ", vault);
        console2.log("  name:           ", name);
        console2.log("  management:     ", management);
        console2.log("");
        console2.log("NOTE: management must call acceptManagement() to finalize ownership transfer.");
    }
}
