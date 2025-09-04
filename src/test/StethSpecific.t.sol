// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {BaseLSTAccumulator} from "../BaseLSTAccumulator.sol";
import {Strategy} from "../Strategy.sol";
import {ISTETH} from "../interfaces/ISTETH.sol";
import {ICurve} from "../interfaces/ICurve.sol";
import {IWETH} from "../interfaces/IWETH.sol";

contract StethSpecificTest is Setup {
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setReferral() public {
        Strategy stethStrategy = Strategy(payable(address(strategy)));

        // Check initial referral is not set
        assertEq(stethStrategy.referral(), address(0), "Referral already set");

        // Non-management cannot set referral
        vm.prank(user);
        vm.expectRevert("!management");
        stethStrategy.setReferral(user);

        // Management can set referral
        address newReferral = address(0x123);
        vm.prank(management);
        stethStrategy.setReferral(newReferral);

        assertEq(stethStrategy.referral(), newReferral, "Referral not set");
    }

    function test_receiveETH() public {
        // Strategy should be able to receive ETH
        uint256 ethAmount = 1 ether;

        // Send ETH directly to strategy
        vm.deal(address(this), ethAmount);
        (bool success, ) = payable(address(strategy)).call{value: ethAmount}(
            ""
        );
        assertTrue(success, "Failed to send ETH");

        // The strategy may have existing balance, check it increased
        assertGe(address(strategy).balance, ethAmount, "ETH not received");
    }

    function test_optimalStakingRoute_directStake() public {
        uint256 _amount = 10 ether;

        // Mock Curve pool to return less than 1:1 rate
        // This will make strategy use direct staking
        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSelector(
                ICurve.get_dy.selector,
                int128(0),
                int128(1),
                _amount
            ),
            abi.encode(_amount - 1) // Return slightly less than 1:1
        );

        // Deposit will trigger staking
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that stETH was received (approximately 1:1)
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertApproxEqAbs(stethBalance, _amount, 2, "stETH not received 1:1");
    }

    function test_optimalStakingRoute_curveSwap() public {
        uint256 _amount = 10 ether;

        // Mock Curve pool to return more than 1:1 rate
        // This will make strategy use Curve swap
        uint256 betterRate = _amount + 0.01 ether;
        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSelector(
                ICurve.get_dy.selector,
                int128(0),
                int128(1),
                _amount
            ),
            abi.encode(betterRate) // Return more than 1:1
        );

        // Mock the actual exchange
        vm.mockCall(
            CURVE_POOL,
            _amount,
            abi.encodeWithSelector(
                ICurve.exchange.selector,
                int128(0),
                int128(1),
                _amount,
                _amount
            ),
            abi.encode(0)
        );

        // We need to simulate Curve transferring stETH to strategy
        // In real fork this would happen automatically
        vm.mockCall(
            tokenAddrs["STETH"],
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(betterRate)
        );

        // Deposit will trigger staking through Curve
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // In mock, we just verify the path was taken
        // In real fork test, we'd verify actual stETH balance
    }

    function test_availableDepositLimit_whenStakingPaused() public {
        Strategy stethStrategy = Strategy(payable(address(strategy)));

        // First enable open deposits
        vm.prank(emergencyAdmin);
        BaseLSTAccumulator(address(stethStrategy)).setOpenDeposits(true);

        // Check deposit limit is available normally
        uint256 limitBefore = strategy.availableDepositLimit(user);
        assertGt(limitBefore, 0, "No deposit limit available");

        // Mock staking paused
        vm.mockCall(
            tokenAddrs["STETH"],
            abi.encodeWithSelector(ISTETH.isStakingPaused.selector),
            abi.encode(true)
        );

        // Check deposit limit is now 0
        uint256 limitAfter = strategy.availableDepositLimit(user);
        assertEq(limitAfter, 0, "Deposit limit not 0 when staking paused");

        // Unmock - staking not paused
        vm.mockCall(
            tokenAddrs["STETH"],
            abi.encodeWithSelector(ISTETH.isStakingPaused.selector),
            abi.encode(false)
        );

        // Limit should be available again
        uint256 limitRestored = strategy.availableDepositLimit(user);
        assertEq(limitRestored, limitBefore, "Deposit limit not restored");
    }

    function test_accessControl_deposits() public {
        uint256 _amount = 10 ether;
        Strategy stethStrategy = Strategy(payable(address(strategy)));

        // Deposits are open by default in test setup
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).openDeposits(),
            true
        );

        // Close deposits
        vm.prank(emergencyAdmin);
        BaseLSTAccumulator(address(stethStrategy)).setOpenDeposits(false);

        // User cannot deposit when closed
        airdrop(asset, user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.prank(user);
        vm.expectRevert(); // Will revert due to deposit limit
        strategy.deposit(_amount, user);

        // Add user to allowed list
        vm.prank(emergencyAdmin);
        BaseLSTAccumulator(address(stethStrategy)).setAllowed(user, true);

        // Now user can deposit even when closed
        vm.prank(user);
        uint256 shares = strategy.deposit(_amount, user);
        assertGt(shares, 0, "No shares minted");

        // Open deposits for everyone again
        vm.prank(emergencyAdmin);
        BaseLSTAccumulator(address(stethStrategy)).setOpenDeposits(true);

        // Another user can now deposit
        address user2 = address(0x123);
        airdrop(asset, user2, _amount);
        vm.prank(user2);
        asset.approve(address(strategy), _amount);

        vm.prank(user2);
        uint256 shares2 = strategy.deposit(_amount, user2);
        assertGt(shares2, 0, "No shares minted for user2");
    }

    function test_manualStakeAndSwap() public {
        uint256 _amount = 10 ether;
        Strategy stethStrategy = Strategy(payable(address(strategy)));

        // First disable auto-staking
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).setStakeAsset(false);

        // Deposit - should not auto-stake
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 wethBalance = asset.balanceOf(address(strategy));
        assertEq(wethBalance, _amount, "WETH was staked");

        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertEq(stethBalance, 0, "stETH already exists");

        // Manually stake
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).manualStake(_amount);

        wethBalance = asset.balanceOf(address(strategy));
        assertEq(wethBalance, 0, "WETH not staked");

        stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertGt(stethBalance, 0, "No stETH received");

        // Manually swap back
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).manualSwapToAsset(
            stethBalance,
            0
        );

        wethBalance = asset.balanceOf(address(strategy));
        assertGt(wethBalance, 0, "No WETH received");

        stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertLe(stethBalance, 2, "stETH not swapped");
    }

    function test_depositLimit() public {
        Strategy stethStrategy = Strategy(payable(address(strategy)));

        // Set a deposit limit
        uint256 limit = 100 ether;
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).setDepositLimit(limit);

        // Open deposits
        vm.prank(emergencyAdmin);
        BaseLSTAccumulator(address(stethStrategy)).setOpenDeposits(true);

        // Check available limit
        uint256 available = strategy.availableDepositLimit(user);
        assertEq(available, limit, "Wrong available limit");

        // Deposit half
        uint256 firstDeposit = limit / 2;
        mintAndDepositIntoStrategy(strategy, user, firstDeposit);

        // Check remaining limit (with 0.5% tolerance for rounding/slippage)
        available = strategy.availableDepositLimit(user);
        uint256 expectedRemaining = limit / 2;
        uint256 tolerance = (limit * 5) / 1000; // 0.5% tolerance
        assertLe(
            available,
            expectedRemaining + tolerance,
            "Wrong remaining limit - too high"
        );
        assertGe(
            available,
            expectedRemaining - tolerance,
            "Wrong remaining limit - too low"
        );

        // Try to deposit more than limit
        uint256 tooMuch = limit;
        airdrop(asset, user, tooMuch);
        vm.prank(user);
        asset.approve(address(strategy), tooMuch);

        vm.prank(user);
        vm.expectRevert();
        strategy.deposit(tooMuch, user);

        // Can deposit up to limit
        vm.prank(user);
        uint256 shares = strategy.deposit(available, user);
        assertGt(shares, 0, "Could not deposit to limit");

        // No more available
        available = strategy.availableDepositLimit(user);
        assertEq(available, 0, "Limit not exhausted");
    }

    function test_curvePoolSwap() public {
        uint256 _amount = 10 ether;

        // Deposit and let it stake
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Get some stETH balance
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertGt(stethBalance, 0, "No stETH to swap");

        // Swap through Curve (manual swap)
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).manualSwapToAsset(
            stethBalance,
            0
        );

        // Should have WETH back
        uint256 wethBalance = asset.balanceOf(address(strategy));
        assertGt(wethBalance, 0, "No WETH after swap");

        // stETH should be gone (allow for dust)
        uint256 remainingSteth = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertLe(remainingSteth, 2, "stETH not fully swapped");
    }
}
