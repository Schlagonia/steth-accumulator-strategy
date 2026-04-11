// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseLSTAccumulator} from "../BaseLSTAccumulator.sol";
import {Setup4626} from "./utils/Setup4626.sol";

contract Strategy4626Test is Setup4626 {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategy4626OK() public {
        assertEq(address(strategy4626.vault()), address(vault4626));
        assertEq(address(strategy4626.wstETH()), tokenAddrs["WSTETH"]);
        assertEq(strategy4626.vault().asset(), tokenAddrs["WSTETH"]);
    }

    function test_depositWrapsAndDeposits(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEqAbs(strategy.totalAssets(), _amount, 3, "!totalAssets");
        assertGt(
            vault4626.balanceOf(address(strategy4626)),
            0,
            "No vault shares"
        );
        assertEq(
            ERC20(tokenAddrs["WSTETH"]).balanceOf(address(strategy4626)),
            0,
            "Loose wstETH"
        );
    }

    function test_reportIncludesVaultPosition(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 vaultAssets = ERC20(tokenAddrs["WSTETH"]).balanceOf(
            address(vault4626)
        );
        uint256 yieldAmount = vaultAssets / 20;
        if (yieldAmount == 0) yieldAmount = 1;

        deal(
            tokenAddrs["WSTETH"],
            address(vault4626),
            vaultAssets + yieldAmount
        );

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertGt(profit, 0, "No profit");
        assertEq(loss, 0, "Unexpected loss");
    }

    function test_manualSwapRedeemsVault(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 sharesBefore = vault4626.balanceOf(address(strategy4626));

        vm.prank(management);
        BaseLSTAccumulator(address(strategy4626)).manualSwapToAsset(_amount, 0);

        assertLt(
            vault4626.balanceOf(address(strategy4626)),
            sharesBefore,
            "Vault not redeemed"
        );
        assertGt(asset.balanceOf(address(strategy4626)), 0, "No loose WETH");
    }

    function test_initiateWithdrawalRedeemsVault(uint256 _amount) public {
        vm.assume(_amount > 1e18 && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 sharesBefore = vault4626.balanceOf(address(strategy4626));

        vm.prank(management);
        BaseLSTAccumulator(address(strategy4626)).initiateLSTWithdrawal(
            _amount / 2
        );

        assertGt(
            BaseLSTAccumulator(address(strategy4626)).pendingRedemptions(),
            0,
            "No pending redemption"
        );
        assertLt(
            vault4626.balanceOf(address(strategy4626)),
            sharesBefore,
            "Vault not redeemed"
        );
    }
}
