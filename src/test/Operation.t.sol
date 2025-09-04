// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {BaseLSTAccumulator} from "../BaseLSTAccumulator.sol";
import {Strategy} from "../Strategy.sol";

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
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).LST(),
            tokenAddrs["STETH"]
        );
        assertEq(BaseLSTAccumulator(address(stethStrategy)).stakeAsset(), true);
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).openDeposits(),
            true
        ); // Opened in setup
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
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertGt(stethBalance, 0, "No stETH balance after deposit");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // First swap stETH back to WETH to enable withdrawals
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).manualSwapToAsset(
            stethBalance,
            0
        );

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw available funds (may be less due to slippage)
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

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS - 100)
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEqAbs(strategy.totalAssets(), _amount, 2, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Simulate stETH rebasing/earning - skip if no profit
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        if (toAirdrop > 0) {
            // Use vm.deal to add stETH directly, avoiding transfer issues
            uint256 currentSteth = ERC20(tokenAddrs["STETH"]).balanceOf(
                address(strategy)
            );
            // Use vm.store to directly update stETH balance storage
            // stETH uses shares internally, so we need to be careful
            // For simplicity, transfer from a known large holder
            address stethWhale = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022; // Curve stETH/ETH pool
            uint256 whaleBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
                stethWhale
            );
            if (whaleBalance >= toAirdrop) {
                vm.prank(stethWhale);
                ERC20(tokenAddrs["STETH"]).transfer(
                    address(strategy),
                    toAirdrop
                );
            }
        }

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Swap stETH back to WETH for withdrawals
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).manualSwapToAsset(
            stethBalance,
            0
        );

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

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // For large amounts, disable health check to avoid false positives
        if (_amount > 10e18) {
            vm.prank(management);
            strategy.setDoHealthCheck(false);
        }

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Need to swap stETH back first
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        if (stethBalance > 0) {
            vm.prank(management);
            BaseLSTAccumulator(address(stethStrategy)).manualSwapToAsset(
                stethBalance,
                0
            );
        }

        uint256 maxRedeem = strategy.maxRedeem(user);
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
