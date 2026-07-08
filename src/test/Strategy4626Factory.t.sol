// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {Strategy4626Factory} from "../Strategy4626Factory.sol";
import {IStrategy4626Interface} from "../interfaces/IStrategy4626Interface.sol";

contract Strategy4626FactoryTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant VAULT = 0xE73b2561309Bed1035D2145275BCA1aEcf85A8F7;

    address public management = address(1);
    address public keeper = address(4);
    address public emergencyAdmin = address(5);
    address public performanceFeeRecipient = address(3);

    Strategy4626Factory public factory;

    function setUp() public {
        factory = new Strategy4626Factory(management, performanceFeeRecipient, keeper, emergencyAdmin, WETH);
    }

    function test_newStrategy4626() public {
        address strategyAddress = factory.newStrategy4626(VAULT);

        IStrategy4626Interface strategy = IStrategy4626Interface(strategyAddress);

        assertEq(factory.deployments(VAULT), strategyAddress, "!deployment");
        assertTrue(factory.isDeployedStrategy(strategyAddress), "!deployedStrategy");
        assertEq(strategy.management(), address(factory), "!management");
        assertEq(strategy.pendingManagement(), management, "!pendingManagement");
        assertEq(strategy.keeper(), keeper, "!keeper");
        assertEq(strategy.emergencyAdmin(), emergencyAdmin, "!emergencyAdmin");
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient, "!performanceFeeRecipient");
        assertEq(strategy.performanceFee(), 0, "!performanceFee");
        assertEq(strategy.profitMaxUnlockTime(), 0, "!profitMaxUnlockTime");
        assertEq(strategy.asset(), WETH, "!asset");
        assertEq(address(strategy.vault()), VAULT, "!vault");
        assertEq(address(strategy.wstETH()), WSTETH, "!wstETH");

        vm.prank(management);
        strategy.acceptManagement();

        assertEq(strategy.management(), management, "!accepted");
        assertEq(strategy.pendingManagement(), address(0), "!pendingCleared");
    }

    function test_newStrategy4626_revertsIfAlreadyDeployed() public {
        address strategyAddress = factory.newStrategy4626(VAULT);

        vm.expectRevert(abi.encodeWithSelector(Strategy4626Factory.AlreadyDeployed.selector, strategyAddress));
        factory.newStrategy4626(VAULT);
    }

    function test_newStrategy4626_revertsWithWrongVaultAsset() public {
        vm.expectRevert();
        factory.newStrategy4626(WETH);
    }

    function test_setAddresses() public {
        address newManagement = address(11);
        address newPerformanceFeeRecipient = address(12);
        address newKeeper = address(13);
        address newEmergencyAdmin = address(14);

        vm.prank(management);
        factory.setAddresses(newManagement, newPerformanceFeeRecipient, newKeeper, newEmergencyAdmin);

        assertEq(factory.management(), newManagement, "!management");
        assertEq(factory.performanceFeeRecipient(), newPerformanceFeeRecipient, "!performanceFeeRecipient");
        assertEq(factory.keeper(), newKeeper, "!keeper");
        assertEq(factory.emergencyAdmin(), newEmergencyAdmin, "!emergencyAdmin");
    }

    function test_setAddresses_revertsIfNotManagement() public {
        vm.expectRevert("!management");
        factory.setAddresses(address(11), address(12), address(13), address(14));
    }
}
