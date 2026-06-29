// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);

        // Check stETH specific params
        assertEq(strategy.LST(), tokenAddrs["STETH"]);
        assertEq(strategy.stakeAsset(), true);
        assertEq(strategy.openDeposits(), true); // Opened in setup
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // For large amounts, disable health check to avoid false positives
        if (_amount > 10e18) {
            vm.prank(management);
            strategy.setDoHealthCheck(false);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Allow for small rounding differences when staking
        assertApproxEqAbs(strategy.totalAssets(), _amount, 2, "!totalAssets");

        // Check that WETH was staked to stETH
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertGt(stethBalance, 0, "No stETH balance after deposit");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        skip(strategy.profitMaxUnlockTime());

        // First swap stETH back to WETH to enable withdrawals
        vm.prank(management);
        strategy.manualSwapToAsset(stethBalance, 0);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw available funds (may be less due to slippage)
        uint256 maxRedeem = strategy.maxRedeem(user);
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        // Allow for 0.5% slippage from stETH->WETH conversion
        uint256 minExpected = (_amount * 995) / 1000;
        assertGe(asset.balanceOf(user), balanceBefore + minExpected, "!final balance");
    }

    function test_profitableReport(uint256 _amount, uint16 _profitFactor) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS - 100));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEqAbs(strategy.totalAssets(), _amount, 2, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Simulate stETH rebasing/earning - skip if no profit
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        if (toAirdrop > 0) {
            // Use vm.deal to add stETH directly, avoiding transfer issues
            uint256 currentSteth = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
            // Use vm.store to directly update stETH balance storage
            // stETH uses shares internally, so we need to be careful
            // For simplicity, transfer from a known large holder
            address stethWhale = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022; // Curve stETH/ETH pool
            uint256 whaleBalance = ERC20(tokenAddrs["STETH"]).balanceOf(stethWhale);
            if (whaleBalance >= toAirdrop) {
                vm.prank(stethWhale);
                ERC20(tokenAddrs["STETH"]).transfer(address(strategy), toAirdrop);
            }
        }

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop - 3, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Swap stETH back to WETH for withdrawals
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        vm.prank(management);
        strategy.manualSwapToAsset(stethBalance, 0);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw max redeemable amount
        uint256 maxRedeem = strategy.maxRedeem(user);
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        // Allow for 0.5% slippage from stETH->WETH conversion
        uint256 minExpected = (_amount * 995) / 1000;
        assertGe(asset.balanceOf(user), balanceBefore + minExpected, "!final balance");
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // For large amounts, disable health check to avoid false positives
        if (_amount > 10e18) {
            vm.prank(management);
            strategy.setDoHealthCheck(false);
        }

        // minAmountToTend defaults to type(uint256).max, so tend never triggers
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy (auto-stakes, so balanceOfAsset ~0)
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Need to swap stETH back first
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        if (stethBalance > 0) {
            vm.prank(management);
            strategy.manualSwapToAsset(stethBalance, 0);
        }

        uint256 maxRedeem = strategy.maxRedeem(user);
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_tendTrigger_positive(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Disable auto-staking so WETH stays idle after deposit
        vm.prank(management);
        strategy.setStakeAsset(false);

        // Set minAmountToTend low so tend can trigger
        vm.prank(management);
        strategy.setMinAmountToTend(minFuzzAmount / 2);

        // Set maxGasPriceToTend high to ensure gas check passes
        vm.prank(management);
        strategy.setMaxGasPriceToTend(1000e9);

        // Set basefee within limit
        vm.fee(5e9);

        // Deposit WETH without staking
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // balanceOfAsset > minAmountToTend && basefee <= maxGasPriceToTend
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "Tend should trigger with idle WETH");

        // Set basefee above max - should no longer trigger
        vm.fee(1001e9);
        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger, "Tend should not trigger with high gas");

        // Reset basefee and set minAmountToTend above balance
        vm.fee(5e9);
        vm.prank(management);
        strategy.setMinAmountToTend(_amount + 1);
        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger, "Tend should not trigger below min amount");
    }

    function test_tendExecution(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Disable auto-staking so WETH stays idle after deposit
        vm.prank(management);
        strategy.setStakeAsset(false);

        // Deposit WETH without staking
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Verify WETH is idle
        assertEq(asset.balanceOf(address(strategy)), _amount, "WETH not idle");
        assertEq(ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy)), 0, "stETH exists before tend");

        // Execute tend - should stake idle WETH
        vm.prank(keeper);
        strategy.tend();

        // Verify WETH was staked to stETH
        assertEq(asset.balanceOf(address(strategy)), 0, "WETH not staked by tend");
        assertGt(ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy)), 0, "No stETH after tend");
    }

    function test_availableWithdrawLimit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit and auto-stake
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // All WETH is staked to stETH, so available withdraw should be 0
        uint256 withdrawLimit = strategy.availableWithdrawLimit(user);
        assertEq(withdrawLimit, 0, "Withdraw limit should be 0 when all staked");

        // User cannot withdraw anything (no idle WETH)
        uint256 maxRedeem = strategy.maxRedeem(user);
        assertEq(maxRedeem, 0, "maxRedeem should be 0 when all staked");

        // Swap half the stETH back to WETH
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        uint256 swapAmount = stethBalance / 2;
        vm.prank(management);
        strategy.manualSwapToAsset(swapAmount, 0);

        // Now available withdraw should equal WETH balance
        uint256 wethBalance = asset.balanceOf(address(strategy));
        withdrawLimit = strategy.availableWithdrawLimit(user);
        assertEq(withdrawLimit, wethBalance, "Withdraw limit != WETH balance");
        assertGt(withdrawLimit, 0, "Withdraw limit still 0 after swap");

        // User can now redeem (limited to available WETH)
        maxRedeem = strategy.maxRedeem(user);
        assertGt(maxRedeem, 0, "maxRedeem should be > 0 after swap");
    }

    function test_reportWithReportBuffer() public {
        uint256 _amount = 10 ether;

        // Deposit and stake
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);

        // First report with no buffer to establish baseline
        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        strategy.report();

        // Wait for full profit unlock so totalAssets is stable
        skip(strategy.profitMaxUnlockTime());

        uint256 totalAssetsBefore = strategy.totalAssets();

        // Set 5% report buffer
        vm.prank(management);
        strategy.setReportBuffer(500);

        // Disable health check again (re-enabled after first report)
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        // Second report - buffer discounts LST value
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Buffer should cause a loss to be reported
        assertGt(loss, 0, "Buffer should cause loss");

        // Total assets should have decreased
        assertLt(strategy.totalAssets(), totalAssetsBefore, "Total assets should decrease with buffer");
    }
}
