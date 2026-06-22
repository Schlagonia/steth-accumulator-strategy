// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";

contract DeployStrategyAprOracle is Script {
    function run() external returns (StrategyAprOracle oracle) {
        vm.startBroadcast();
        oracle = new StrategyAprOracle();
        vm.stopBroadcast();

        console2.log("StrategyAprOracle:", address(oracle));
    }
}
