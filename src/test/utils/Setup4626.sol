// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./Setup.sol";
import {IStrategy4626Interface} from "../../interfaces/IStrategy4626Interface.sol";
import {Strategy4626} from "../../Strategy4626.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/ERC4626Mock.sol";

contract Setup4626 is Setup {
    IStrategy4626Interface public strategy4626;
    ERC4626Mock public vault4626;

    function setUp() public virtual override {
        super.setUp();

        vm.label(address(vault4626), "vault4626");
        vm.label(address(strategy4626), "strategy4626");
    }

    function setUpStrategy() public virtual override returns (address) {
        vault4626 = new ERC4626Mock(tokenAddrs["WSTETH"]);
        vault4626 = ERC4626Mock(0xE73b2561309Bed1035D2145275BCA1aEcf85A8F7);

        address man = IStrategy4626Interface(address(vault4626)).management();

        IStrategy4626Interface _strategy = IStrategy4626Interface(
            address(new Strategy4626(address(asset), "Tokenized Strategy 4626", address(vault4626)))
        );
        strategy4626 = _strategy;

        _strategy.setPendingManagement(management);
        _strategy.setKeeper(keeper);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setLossLimitRatio(1);
        _strategy.setOpenDeposits(true);

        vm.prank(management);
        _strategy.acceptManagement();

        vm.prank(man);
        IStrategy4626Interface(address(vault4626)).setAllowed(address(_strategy), true);

        return address(_strategy);
    }
}
