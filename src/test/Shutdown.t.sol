pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {BaseLSTAccumulator} from "../BaseLSTAccumulator.sol";
import {Strategy} from "../Strategy.sol";

contract ShutdownTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // For large amounts, disable health check
        if (_amount > 10e18) {
            vm.prank(management);
            strategy.setDoHealthCheck(false);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEqAbs(strategy.totalAssets(), _amount, 2, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertApproxEqAbs(strategy.totalAssets(), _amount, 2, "!totalAssets");

        // Emergency withdraw to convert stETH back to WETH
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw max redeemable amount
        uint256 maxRedeem = strategy.maxRedeem(user);
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        // Allow for 0.5% slippage from stETH->WETH conversion
        uint256 minExpected = (_amount * 995) / 1000;
        assertGe(
            asset.balanceOf(user),
            balanceBefore + minExpected,
            "!final balance"
        );
    }

    function test_emergencyWithdraw_maxUint(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // For large amounts, disable health check
        if (_amount > 10e18) {
            vm.prank(management);
            strategy.setDoHealthCheck(false);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEqAbs(strategy.totalAssets(), _amount, 2, "!totalAssets");

        // Check that funds are in stETH
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertGt(stethBalance, 0, "No stETH balance after deposit");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertApproxEqAbs(strategy.totalAssets(), _amount, 2, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        // This will swap all stETH back to WETH
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Check that stETH was swapped back (allow for dust)
        uint256 stethBalanceAfter = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertLe(stethBalanceAfter, 2, "stETH not fully swapped");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw max redeemable amount
        uint256 maxRedeem = strategy.maxRedeem(user);
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        // Allow for 0.5% slippage from stETH->WETH conversion
        uint256 minExpected = (_amount * 995) / 1000;
        assertGe(
            asset.balanceOf(user),
            balanceBefore + minExpected,
            "!final balance"
        );
    }

    function test_emergencyWithdraw_withStETH(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // For large amounts, disable health check
        if (_amount > 10e18) {
            vm.prank(management);
            strategy.setDoHealthCheck(false);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Wait for harvest
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        // Verify stETH position exists
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBefore = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertGt(stethBefore, 0, "No stETH balance");

        // Shutdown and emergency withdraw
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(_amount / 2); // Withdraw half

        // Check that some stETH was swapped (allow for rounding)
        uint256 stethAfter = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertLe(stethAfter, stethBefore, "stETH not reduced");
    }

    // Additional tests for BaseLSTAccumulator emergency functions
}
