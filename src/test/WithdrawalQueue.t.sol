// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {MockWithdrawalQueue} from "./mocks/MockWithdrawalQueue.sol";

contract WithdrawalQueueTest is Setup {
    address constant WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    MockWithdrawalQueue mockQueue;

    function setUp() public virtual override {
        super.setUp();

        // Deploy mock queue
        mockQueue = new MockWithdrawalQueue();

        // Copy the runtime code to the withdrawal queue address
        bytes memory runtimeCode = address(mockQueue).code;
        vm.etch(WITHDRAWAL_QUEUE, runtimeCode);

        // Initialize the storage slot for nextRequestId to 1
        // Slot 0 is withdrawalAmounts mapping, slot 1 is nextRequestId
        vm.store(WITHDRAWAL_QUEUE, bytes32(uint256(1)), bytes32(uint256(1)));

        // Fund the mock queue with ETH for claims
        vm.deal(WITHDRAWAL_QUEUE, 1000 ether);
    }

    // No need for mock functions anymore, the MockWithdrawalQueue handles it

    function test_initiateLSTWithdrawal() public {
        uint256 _amount = 10e18;

        // Deposit and harvest to get stETH
        mintAndDepositIntoStrategy(strategy, user, _amount);

        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        // Check stETH balance
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));
        assertGt(stethBalance, 0, "No stETH to withdraw");

        vm.prank(management);
        strategy.setReportBuffer(100);

        uint256 estimatedBefore = strategy.estimatedTotalAssets();
        uint256 depositLimitBefore = strategy.availableDepositLimit(user);

        // Initiate withdrawal (will use real mock queue)
        vm.prank(management);
        bytes memory returnData = strategy.initiateLSTWithdrawal(stethBalance);

        // Decode request ID
        uint256 requestId = abi.decode(returnData, (uint256));
        assertGt(requestId, 0, "Invalid request ID");

        // Check pending redemptions updated
        assertEq(strategy.pendingRedemptions(), stethBalance, "Pending redemptions not updated");
        assertApproxEqAbs(strategy.estimatedTotalAssets(), estimatedBefore, 2, "Pending redemption not valued");
        assertApproxEqAbs(
            strategy.availableDepositLimit(user), depositLimitBefore, 2, "Withdrawal reopened deposit limit"
        );
    }

    function test_claimLSTWithdrawal() public {
        uint256 _amount = 10e18;

        // Setup: deposit, harvest, and initiate withdrawal
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));

        // Initiate withdrawal
        vm.prank(management);
        bytes memory returnData = strategy.initiateLSTWithdrawal(stethBalance);
        uint256 requestId = abi.decode(returnData, (uint256));
        assertGt(requestId, 0, "Invalid request ID");
        uint256 estimatedBefore = strategy.estimatedTotalAssets();
        uint256 ethBefore = address(strategy).balance;

        // Get WETH balance before
        uint256 wethBefore = asset.balanceOf(address(strategy));

        // Claim withdrawal (mock queue will send ETH)
        vm.prank(keeper);
        uint256 claimedAmount = strategy.claimLSTWithdrawal(returnData);

        // Check the claimed amount matches
        assertApproxEqAbs(claimedAmount, stethBalance, 2, "Wrong claimed amount");

        // Check WETH was received
        uint256 wethAfter = asset.balanceOf(address(strategy));
        assertGe(wethAfter - wethBefore, claimedAmount, "WETH not received");

        // Check pending redemptions cleared
        assertEq(strategy.pendingRedemptions(), 0, "Pending redemptions not cleared");
        assertApproxEqAbs(
            strategy.estimatedTotalAssets(), estimatedBefore + ethBefore, 2, "Claim changed estimated assets"
        );

        vm.prank(user);
        vm.expectRevert("!keeper");
        strategy.claimLSTWithdrawal(returnData);
    }

    function test_cannotHarvestWithPendingRedemptions() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));

        // Initiate withdrawal
        vm.prank(management);
        bytes memory returnData = strategy.initiateLSTWithdrawal(stethBalance / 2);

        // Try to harvest - should revert with pending redemptions
        vm.prank(keeper);
        vm.expectRevert(bytes("Pending redemptions"));
        strategy.report();

        // Complete the withdrawal (mock queue handles ETH transfer)

        vm.prank(keeper);
        strategy.claimLSTWithdrawal(returnData);

        // Now harvest should work
        vm.prank(keeper);
        (uint256 profit,) = strategy.report();
        assertGe(profit, 0, "Report failed after clearing redemptions");
    }

    function test_multipleWithdrawalRequests() public {
        uint256 _amount = 100e18;

        // Setup with large deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));

        // Initiate two withdrawals before claiming either one.
        uint256 firstWithdrawal = stethBalance / 3;
        uint256 secondWithdrawal = stethBalance / 3;

        vm.prank(management);
        bytes memory returnData1 = strategy.initiateLSTWithdrawal(firstWithdrawal);
        uint256 requestId1 = abi.decode(returnData1, (uint256));
        assertGt(requestId1, 0, "Invalid first request ID");

        vm.prank(management);
        bytes memory returnData2 = strategy.initiateLSTWithdrawal(secondWithdrawal);
        uint256 requestId2 = abi.decode(returnData2, (uint256));
        assertGt(requestId2, requestId1, "Invalid second request ID");

        assertEq(
            strategy.pendingRedemptions(), firstWithdrawal + secondWithdrawal, "Pending redemptions not accumulated"
        );

        // Cannot harvest with pending
        vm.prank(keeper);
        vm.expectRevert("Pending redemptions");
        strategy.report();

        // Claiming one request should leave the other pending.
        vm.prank(keeper);
        strategy.claimLSTWithdrawal(returnData1);
        assertEq(strategy.pendingRedemptions(), secondWithdrawal, "Wrong pending amount after first claim");

        vm.prank(keeper);
        vm.expectRevert("Pending redemptions");
        strategy.report();

        vm.prank(keeper);
        strategy.claimLSTWithdrawal(returnData2);
        assertEq(strategy.pendingRedemptions(), 0, "Pending redemptions not cleared");

        vm.prank(keeper);
        strategy.report();
    }

    function test_clearPendingRedemptions() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest to get stETH
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));

        // Initiate withdrawal to create pending redemptions
        vm.prank(management);
        strategy.initiateLSTWithdrawal(stethBalance);

        uint256 pending = strategy.pendingRedemptions();
        assertEq(pending, stethBalance, "Pending not set");
        uint256 estimatedBeforeClear = strategy.estimatedTotalAssets();

        // Cannot harvest with pending
        vm.prank(keeper);
        vm.expectRevert("Pending redemptions");
        strategy.report();

        // Partially clear
        uint256 halfPending = pending / 2;
        vm.prank(management);
        strategy.clearPendingRedemptions(halfPending);
        assertEq(strategy.pendingRedemptions(), pending - halfPending, "Partial clear failed");
        assertEq(
            estimatedBeforeClear - strategy.estimatedTotalAssets(), halfPending, "Partial clear not reflected in value"
        );

        // Still cannot harvest
        vm.prank(keeper);
        vm.expectRevert("Pending redemptions");
        strategy.report();

        // Clear remaining
        vm.prank(management);
        strategy.clearPendingRedemptions(pending);
        assertEq(strategy.pendingRedemptions(), 0, "Full clear failed");
        assertEq(estimatedBeforeClear - strategy.estimatedTotalAssets(), pending, "Full clear not reflected in value");

        // Non-management cannot clear
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.clearPendingRedemptions(1);
    }

    function test_manualClaimWithdrawals() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));

        // Initiate withdrawal through normal path
        vm.prank(management);
        bytes memory returnData = strategy.initiateLSTWithdrawal(stethBalance);
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = abi.decode(returnData, (uint256));

        uint256 wethBefore = asset.balanceOf(address(strategy));

        // Use manualClaimWithdrawals with zeroRedemptions=true
        uint256[] memory hints = new uint256[](1);
        hints[0] = 0; // Mock doesn't use hints

        vm.prank(management);
        strategy.manualClaimWithdrawals(requestIds, hints, true);

        // Check WETH was received
        uint256 wethAfter = asset.balanceOf(address(strategy));
        assertGt(wethAfter, wethBefore, "WETH not received");

        // Check pending redemptions zeroed
        assertEq(strategy.pendingRedemptions(), 0, "Pending redemptions not zeroed");

        // Non-emergency-authorized cannot call
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.manualClaimWithdrawals(requestIds, hints, false);
    }

    function test_manualClaimWithdrawals_keepRedemptions() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy));

        // Initiate withdrawal
        vm.prank(management);
        bytes memory returnData = strategy.initiateLSTWithdrawal(stethBalance);

        uint256 pendingBefore = strategy.pendingRedemptions();
        assertGt(pendingBefore, 0, "No pending redemptions");

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = abi.decode(returnData, (uint256));
        uint256[] memory hints = new uint256[](1);
        hints[0] = 0;

        // Claim with zeroRedemptions=false
        vm.prank(management);
        strategy.manualClaimWithdrawals(requestIds, hints, false);

        // Pending redemptions should NOT be zeroed
        assertEq(strategy.pendingRedemptions(), pendingBefore, "Pending redemptions should not change");
    }
}
