// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup, IStrategyInterface} from "./Setup.sol";
import {BaseLSTAccumulator} from "../../BaseLSTAccumulator.sol";
import {Strategy4626} from "../../Strategy4626.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/ERC4626Mock.sol";

contract Setup4626 is Setup {
    Strategy4626 public strategy4626;
    ERC4626Mock public vault4626;

    function setUp() public virtual override {
        super.setUp();

        vm.label(address(vault4626), "vault4626");
        vm.label(address(strategy4626), "strategy4626");
    }

    function setUpStrategy() public virtual override returns (address) {
        vault4626 = new ERC4626Mock(tokenAddrs["WSTETH"]);

        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new Strategy4626(
                    address(asset),
                    "Tokenized Strategy 4626",
                    address(vault4626)
                )
            )
        );
        strategy4626 = Strategy4626(payable(address(_strategy)));

        _strategy.setPendingManagement(management);
        _strategy.setKeeper(keeper);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        vm.prank(management);
        _strategy.acceptManagement();

        vm.prank(emergencyAdmin);
        BaseLSTAccumulator(address(_strategy)).setOpenDeposits(true);

        return address(_strategy);
    }
}
