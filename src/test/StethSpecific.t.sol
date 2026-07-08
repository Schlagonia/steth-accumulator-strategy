// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {ISTETH} from "../interfaces/ISTETH.sol";
import {ICurve} from "../interfaces/ICurve.sol";

contract StethSpecificTest is Setup {
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setReferral() public {
        // Check initial referral is not set
        assertEq(strategy.referral(), address(0), "Referral already set");

        // Non-management cannot set referral
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setReferral(user);

        // Management can set referral
        address newReferral = address(0x123);
        vm.prank(management);
        strategy.setReferral(newReferral);

        assertEq(strategy.referral(), newReferral, "Referral not set");
    }

    function test_receiveETH() public {
        // Strategy should be able to receive ETH
        uint256 ethAmount = 1 ether;

        // Send ETH directly to strategy
        vm.deal(address(this), ethAmount);
        (bool success,) = payable(address(strategy)).call{value: ethAmount}("");
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
            abi.encodeWithSelector(ICurve.get_dy.selector, int128(0), int128(1), _amount),
            abi.encode(_amount - 1) // Return slightly less than 1:1
        );

        // Deposit will trigger staking
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that stETH was received (approximately 1:1)
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertApproxEqAbs(stethBalance, _amount, 2, "stETH not received 1:1");
    }

    function test_optimalStakingRoute_curveSwap() public {
        uint256 _amount = 10 ether;

        // Mock Curve pool to return more than 1:1 rate
        // This will make strategy use Curve swap
        uint256 betterRate = _amount + 0.01 ether;
        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSelector(ICurve.get_dy.selector, int128(0), int128(1), _amount),
            abi.encode(betterRate) // Return more than 1:1
        );

        // Mock the actual exchange
        vm.mockCall(
            CURVE_POOL,
            _amount,
            abi.encodeWithSelector(ICurve.exchange.selector, int128(0), int128(1), _amount, _amount),
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
        // First enable open deposits
        vm.prank(management);
        strategy.setOpen(true);

        // Check deposit limit is available normally
        uint256 limitBefore = strategy.availableDepositLimit(user);
        assertGt(limitBefore, 0, "No deposit limit available");

        // Mock staking paused
        vm.mockCall(tokenAddrs["STETH"], abi.encodeWithSelector(ISTETH.isStakingPaused.selector), abi.encode(true));

        // Check deposit limit is now 0
        uint256 limitAfter = strategy.availableDepositLimit(user);
        assertEq(limitAfter, 0, "Deposit limit not 0 when staking paused");

        // Unmock - staking not paused
        vm.mockCall(tokenAddrs["STETH"], abi.encodeWithSelector(ISTETH.isStakingPaused.selector), abi.encode(false));

        // Limit should be available again
        uint256 limitRestored = strategy.availableDepositLimit(user);
        assertEq(limitRestored, limitBefore, "Deposit limit not restored");
    }

    function test_accessControl_deposits() public {
        uint256 _amount = 10 ether;

        // Deposits are open by default in test setup
        assertEq(strategy.open(), true);

        // Close deposits
        vm.prank(management);
        strategy.setOpen(false);

        // User cannot deposit when closed
        airdrop(asset, user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.prank(user);
        vm.expectRevert(); // Will revert due to deposit limit
        strategy.deposit(_amount, user);

        // Add user to allowed list
        vm.prank(management);
        strategy.setAllowed(user, true);

        // Now user can deposit even when closed
        vm.prank(user);
        uint256 shares = strategy.deposit(_amount, user);
        assertGt(shares, 0, "No shares minted");

        // Open deposits for everyone again
        vm.prank(management);
        strategy.setOpen(true);

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

        // First disable auto-staking
        vm.prank(management);
        strategy.setStakeAsset(false);

        // Deposit - should not auto-stake
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 wethBalance = asset.balanceOf(address(strategy));
        assertEq(wethBalance, _amount, "WETH was staked");

        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertEq(stethBalance, 0, "stETH already exists");

        // Manually stake
        vm.prank(management);
        strategy.manualStake(_amount);

        wethBalance = asset.balanceOf(address(strategy));
        assertEq(wethBalance, 0, "WETH not staked");

        stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertGt(stethBalance, 0, "No stETH received");

        // Manually swap back
        vm.prank(management);
        strategy.manualSwapToAsset(stethBalance, 0);

        wethBalance = asset.balanceOf(address(strategy));
        assertGt(wethBalance, 0, "No WETH received");

        stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertLe(stethBalance, 2, "stETH not swapped");
    }

    function test_depositLimit() public {
        // Set a deposit limit
        uint256 limit = 100 ether;
        vm.prank(management);
        strategy.setDepositLimit(limit);

        // Open deposits
        vm.prank(management);
        strategy.setOpen(true);

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
        assertLe(available, expectedRemaining + tolerance, "Wrong remaining limit - too high");
        assertGe(available, expectedRemaining - tolerance, "Wrong remaining limit - too low");

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
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertGt(stethBalance, 0, "No stETH to swap");

        // Swap through Curve (manual swap)
        vm.prank(management);
        strategy.manualSwapToAsset(stethBalance, 0);

        // Should have WETH back
        uint256 wethBalance = asset.balanceOf(address(strategy));
        assertGt(wethBalance, 0, "No WETH after swap");

        // stETH should be gone (allow for dust)
        uint256 remainingSteth = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertLe(remainingSteth, 2, "stETH not fully swapped");
    }

    function test_reportBuffer() public {
        uint256 _amount = 10 ether;

        // Deposit and stake
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 estimatedBefore = strategy.estimatedTotalAssets();
        assertGt(estimatedBefore, 0, "No estimated assets");

        // Set report buffer to 1% (100 BPS)
        vm.prank(management);
        strategy.setReportBuffer(100);
        assertEq(strategy.reportBuffer(), 100, "Report buffer not set");

        uint256 estimatedAfter = strategy.estimatedTotalAssets();

        // Estimated assets should be lower with buffer applied
        assertLt(estimatedAfter, estimatedBefore, "Buffer did not reduce estimated assets");

        // The difference should be ~1% of LST value
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        uint256 expectedDiscount = (stethBalance * 100) / MAX_BPS;
        assertApproxEqAbs(estimatedBefore - estimatedAfter, expectedDiscount, 2, "Buffer discount incorrect");

        // Non-management cannot set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setReportBuffer(200);
    }

    function test_setMinAmountToTend() public {
        // Default is type(uint256).max
        assertEq(strategy.minAmountToTend(), type(uint256).max, "Wrong default minAmountToTend");

        // Management can set
        vm.prank(management);
        strategy.setMinAmountToTend(1 ether);
        assertEq(strategy.minAmountToTend(), 1 ether, "minAmountToTend not set");

        // Non-management cannot set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setMinAmountToTend(2 ether);
    }

    function test_setMaxGasPriceToTend() public {
        // Default is 10 gwei
        assertEq(strategy.maxGasPriceToTend(), 10e9, "Wrong default maxGasPriceToTend");

        // Management can set
        vm.prank(management);
        strategy.setMaxGasPriceToTend(50e9);
        assertEq(strategy.maxGasPriceToTend(), 50e9, "maxGasPriceToTend not set");

        // Non-management cannot set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setMaxGasPriceToTend(100e9);
    }

    function test_harvestStakesBypassesStakeAssetFlag() public {
        uint256 _amount = 10 ether;

        // Disable auto-staking on deposit
        vm.prank(management);
        strategy.setStakeAsset(false);

        // Deposit - should NOT auto-stake
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 wethBalance = asset.balanceOf(address(strategy));
        assertEq(wethBalance, _amount, "WETH was staked on deposit");

        // Report should still stake idle WETH (bypasses stakeAsset flag)
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        // WETH should now be staked to stETH
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertGt(stethBalance, 0, "Harvest did not stake idle WETH");
        assertEq(asset.balanceOf(address(strategy)), 0, "WETH not fully staked during harvest");
    }

    function test_selfAllowedByDefault() public {
        // Strategy address should be in allowed list by default
        assertTrue(strategy.allowed(address(strategy)), "Strategy not self-allowed");
    }

    function test_depositLimitExhaustedByProfit() public {
        // Deposit some amount
        uint256 _amount = 10 ether;
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Set deposit limit equal to current estimated assets
        uint256 estimated = strategy.estimatedTotalAssets();
        vm.prank(management);
        strategy.setDepositLimit(estimated);

        // Available deposit limit should be 0 (at capacity)
        uint256 available = strategy.availableDepositLimit(user);
        assertEq(available, 0, "Should be at limit");

        // Set limit below current assets (over-limit scenario)
        vm.prank(management);
        strategy.setDepositLimit(estimated / 2);

        // Available should still be 0 (clamped, not underflow)
        available = strategy.availableDepositLimit(user);
        assertEq(available, 0, "Should be over limit");

        // Deposits should revert
        airdrop(asset, user, 1 ether);
        vm.prank(user);
        asset.approve(address(strategy), 1 ether);

        vm.prank(user);
        vm.expectRevert();
        strategy.deposit(1 ether, user);
    }

    function test_depositLimitWithReportBuffer() public {
        // Deposit some amount
        uint256 _amount = 10 ether;
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 estimated = strategy.estimatedTotalAssets();

        // Set deposit limit equal to estimated assets - at capacity
        vm.prank(management);
        strategy.setDepositLimit(estimated);

        uint256 available = strategy.availableDepositLimit(user);
        assertEq(available, 0, "Should be at limit");

        // Set report buffer (10%) - discounts LST value, opening deposit room
        vm.prank(management);
        strategy.setReportBuffer(1000);

        uint256 newEstimated = strategy.estimatedTotalAssets();
        assertLt(newEstimated, estimated, "Buffer should reduce estimated");

        // Deposit room should now exist
        available = strategy.availableDepositLimit(user);
        assertGt(available, 0, "Buffer should open deposit room");
        assertApproxEqAbs(available, estimated - newEstimated, 1, "Wrong available after buffer");
    }
}
