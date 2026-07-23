// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Setup4626} from "./utils/Setup4626.sol";

contract Strategy4626Test is Setup4626 {
    event MaxLossUpdated(uint256 indexed maxLoss);

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategy4626OK() public {
        assertEq(address(strategy4626.vault()), address(vault4626));
        assertEq(address(strategy4626.wstETH()), tokenAddrs["WSTETH"]);
        assertEq(strategy4626.vault().asset(), tokenAddrs["WSTETH"]);
        assertEq(strategy4626.maxLoss(), 0);
    }

    function test_setMaxLoss() public {
        uint256 newMaxLoss = 123;

        vm.expectEmit(true, true, true, true, address(strategy4626));
        emit MaxLossUpdated(newMaxLoss);

        vm.prank(management);
        strategy4626.setMaxLoss(newMaxLoss);

        assertEq(strategy4626.maxLoss(), newMaxLoss);
    }

    function test_setMaxLoss_revertsAboveMaxBps() public {
        vm.prank(management);
        vm.expectRevert("Invalid max loss");
        strategy4626.setMaxLoss(MAX_BPS + 1);
    }

    function test_setMaxLoss_accessControl() public {
        vm.prank(user);
        vm.expectRevert("!management");
        strategy4626.setMaxLoss(1);
    }

    function test_depositWrapsAndDeposits(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEqAbs(strategy.totalAssets(), _amount, 3, "!totalAssets");
        assertGt(vault4626.balanceOf(address(strategy4626)), 0, "No vault shares");
        assertEq(ERC20(tokenAddrs["WSTETH"]).balanceOf(address(strategy4626)), 0, "Loose wstETH");
    }

    function test_reportIncludesVaultPosition(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertGt(vault4626.balanceOf(address(strategy4626)), 0, "No vault shares");

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertLe(loss, 3, "Unexpected loss"); // Give for rounding
    }

    function test_manualSwapRedeemsVault(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 sharesBefore = vault4626.balanceOf(address(strategy4626));
        uint256 newMaxLoss = 123;

        vm.prank(management);
        strategy4626.setMaxLoss(newMaxLoss);

        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy4626));
        uint256 neededWstETH = strategy4626.wstETH().getWstETHByStETH(_amount - stethBalance) + 2;
        uint256 wrappedBalance = strategy4626.balanceOfWstETH();
        uint256 shares = vault4626.previewWithdraw(neededWstETH - wrappedBalance);
        uint256 maxRedeem = vault4626.maxRedeem(address(strategy4626));
        if (shares > maxRedeem) shares = maxRedeem;

        vm.expectCall(
            address(vault4626),
            abi.encodeWithSignature(
                "redeem(uint256,address,address,uint256)",
                shares,
                address(strategy4626),
                address(strategy4626),
                newMaxLoss
            )
        );

        vm.prank(management);
        strategy4626.manualSwapToAsset(_amount, 1);

        assertLt(vault4626.balanceOf(address(strategy4626)), sharesBefore, "Vault not redeemed");
        assertGt(asset.balanceOf(address(strategy4626)), 0, "No loose WETH");
    }

    function test_manualRedeemAndUnwrap() public {
        uint256 _amount = 10 ether;

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 sharesBefore = vault4626.balanceOf(address(strategy4626));
        assertGt(sharesBefore, 0, "No vault shares");

        uint256 newMaxLoss = 123;
        vm.prank(management);
        strategy4626.setMaxLoss(newMaxLoss);

        vm.expectCall(
            address(vault4626),
            abi.encodeWithSignature(
                "redeem(uint256,address,address,uint256)",
                sharesBefore,
                address(strategy4626),
                address(strategy4626),
                newMaxLoss
            )
        );

        vm.prank(emergencyAdmin);
        strategy4626.manualRedeem(type(uint256).max);

        assertEq(vault4626.balanceOf(address(strategy4626)), 0, "Vault shares remain");

        uint256 wrappedBalance = strategy4626.balanceOfWstETH();
        assertGt(wrappedBalance, 0, "No wstETH redeemed");

        vm.prank(emergencyAdmin);
        strategy4626.manualUnwrap(type(uint256).max);

        assertEq(strategy4626.balanceOfWstETH(), 0, "wstETH remains");
        assertGt(ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy4626)), 0, "No stETH unwrapped");

        // Empty balances are clean no-ops.
        vm.prank(emergencyAdmin);
        strategy4626.manualRedeem(1);
        vm.prank(emergencyAdmin);
        strategy4626.manualUnwrap(1);
    }

    function test_manualRedeemAndUnwrap_accessControl() public {
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy4626.manualRedeem(1);

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy4626.manualUnwrap(1);
    }

    function test_emergencyWithdrawFreesMixedLSTPosition() public {
        uint256 _amount = 10 ether;

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 shares = vault4626.balanceOf(address(strategy4626));
        vm.prank(emergencyAdmin);
        strategy4626.manualRedeem(shares / 2);

        vm.prank(emergencyAdmin);
        strategy4626.manualUnwrap(type(uint256).max);

        uint256 looseSteth = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy4626));
        uint256 vaultValue = strategy4626.valueOfWstETH();
        uint256 toWithdraw = looseSteth + (vaultValue / 2);
        uint256 sharesBeforeWithdraw = vault4626.balanceOf(address(strategy4626));

        assertGt(looseSteth, 0, "No loose stETH");
        assertGt(vaultValue, 0, "No vault position");
        assertGt(toWithdraw, looseSteth, "Withdrawal does not need vault funds");

        vm.prank(management);
        strategy4626.setReportBuffer(50);
        vm.prank(emergencyAdmin);
        strategy4626.shutdownStrategy();

        uint256 wethBefore = asset.balanceOf(address(strategy4626));
        vm.prank(emergencyAdmin);
        strategy4626.emergencyWithdraw(toWithdraw);

        assertGe(
            asset.balanceOf(address(strategy4626)) - wethBefore,
            (toWithdraw * (MAX_BPS - 50)) / MAX_BPS,
            "Wrong emergency withdrawal amount"
        );
        assertLt(vault4626.balanceOf(address(strategy4626)), sharesBeforeWithdraw, "Vault funds not freed");
    }

    function test_initiateWithdrawalRedeemsVault(uint256 _amount) public {
        vm.assume(_amount > 1e18 && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 sharesBefore = vault4626.balanceOf(address(strategy4626));
        uint256 estimatedBefore = strategy4626.estimatedTotalAssets();
        uint256 withdrawalAmount = _amount / 2;

        vm.prank(management);
        bytes memory returnData = strategy4626.initiateLSTWithdrawal(withdrawalAmount);

        assertGt(abi.decode(returnData, (uint256)), 0, "Invalid request ID");
        assertEq(strategy4626.pendingRedemptions(), withdrawalAmount, "Wrong pending redemption");
        assertApproxEqAbs(strategy4626.estimatedTotalAssets(), estimatedBefore, 10, "Pending redemption not valued");
        assertLt(vault4626.balanceOf(address(strategy4626)), sharesBefore, "Vault not redeemed");
    }
}
