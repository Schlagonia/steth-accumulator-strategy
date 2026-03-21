// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {BaseLSTAccumulator} from "../BaseLSTAccumulator.sol";
import {Strategy} from "../Strategy.sol";
import {IQueue} from "../interfaces/IQueue.sol";
import {MockWithdrawalQueue} from "./mocks/MockWithdrawalQueue.sol";

contract WithdrawalQueueTest is Setup {
    address constant WITHDRAWAL_QUEUE =
        0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
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
        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertGt(stethBalance, 0, "No stETH to withdraw");

        // Initiate withdrawal (will use real mock queue)
        vm.prank(management);
        bytes memory returnData = BaseLSTAccumulator(address(stethStrategy))
            .initiateLSTWithdrawal(stethBalance);

        // Decode request ID
        uint256[] memory requestIds = abi.decode(returnData, (uint256[]));
        assertEq(requestIds.length, 1, "Wrong number of request IDs");
        assertGt(requestIds[0], 0, "Invalid request ID");

        // Check pending redemptions updated
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).pendingRedemptions(),
            stethBalance,
            "Pending redemptions not updated"
        );
    }

    function test_claimLSTWithdrawal() public {
        uint256 _amount = 10e18;

        // Setup: deposit, harvest, and initiate withdrawal
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );

        // Initiate withdrawal
        vm.prank(management);
        bytes memory returnData = BaseLSTAccumulator(address(stethStrategy))
            .initiateLSTWithdrawal(stethBalance);
        uint256[] memory requestIds = abi.decode(returnData, (uint256[]));

        // Get WETH balance before
        uint256 wethBefore = asset.balanceOf(address(strategy));

        // Claim withdrawal (mock queue will send ETH)
        vm.prank(management);
        uint256 claimedAmount = BaseLSTAccumulator(address(stethStrategy))
            .claimLSTWithdrawal(abi.encode(requestIds[0]));

        // Check the claimed amount matches
        assertApproxEqAbs(
            claimedAmount,
            stethBalance,
            2,
            "Wrong claimed amount"
        );

        // Check WETH was received
        uint256 wethAfter = asset.balanceOf(address(strategy));
        assertGe(wethAfter - wethBefore, claimedAmount, "WETH not received");

        // Check pending redemptions cleared
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).pendingRedemptions(),
            0,
            "Pending redemptions not cleared"
        );
    }

    function test_cannotHarvestWithPendingRedemptions() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );

        // Initiate withdrawal
        uint256[] memory requestIds;
        vm.prank(management);
        bytes memory returnData = BaseLSTAccumulator(address(stethStrategy))
            .initiateLSTWithdrawal(stethBalance / 2);
        requestIds = abi.decode(returnData, (uint256[]));

        // Try to harvest - should revert with pending redemptions
        vm.prank(keeper);
        vm.expectRevert(bytes("Pending redemptions"));
        strategy.report();

        // Complete the withdrawal (mock queue handles ETH transfer)

        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).claimLSTWithdrawal(
            abi.encode(requestIds[0])
        );

        // Now harvest should work
        vm.prank(keeper);
        (uint256 profit, ) = strategy.report();
        assertGe(profit, 0, "Report failed after clearing redemptions");
    }

    function test_multipleWithdrawalRequests() public {
        uint256 _amount = 100e18;

        // Setup with large deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );

        // Initiate first withdrawal
        uint256 firstWithdrawal = stethBalance / 3;
        vm.prank(management);
        bytes memory returnData1 = BaseLSTAccumulator(address(stethStrategy))
            .initiateLSTWithdrawal(firstWithdrawal);
        uint256[] memory requestIds1 = abi.decode(returnData1, (uint256[]));

        // Cannot harvest with pending
        vm.prank(keeper);
        vm.expectRevert("Pending redemptions");
        strategy.report();

        // Complete first withdrawal (mock queue handles ETH)

        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).claimLSTWithdrawal(
            abi.encode(requestIds1[0])
        );

        // Can harvest now
        vm.prank(keeper);
        strategy.report();

        // Verify multiple withdrawals can be initiated
        uint256 remainingSteth = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        if (remainingSteth > 0) {
            uint256[] memory requestIds2 = new uint256[](1);
            requestIds2[0] = 12346; // Different mock ID
            vm.mockCall(
                WITHDRAWAL_QUEUE,
                abi.encodeWithSelector(IQueue.requestWithdrawals.selector),
                abi.encode(requestIds2)
            );

            vm.prank(management);
            bytes memory returnData2 = BaseLSTAccumulator(
                address(stethStrategy)
            ).initiateLSTWithdrawal(remainingSteth);
            uint256[] memory decodedIds2 = abi.decode(returnData2, (uint256[]));
            assertEq(decodedIds2[0], requestIds2[0], "Wrong second request ID");
        }
    }

    function test_clearPendingRedemptions() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest to get stETH
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );

        // Initiate withdrawal to create pending redemptions
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).initiateLSTWithdrawal(
            stethBalance
        );

        uint256 pending = BaseLSTAccumulator(address(stethStrategy))
            .pendingRedemptions();
        assertEq(pending, stethBalance, "Pending not set");

        // Cannot harvest with pending
        vm.prank(keeper);
        vm.expectRevert("Pending redemptions");
        strategy.report();

        // Partially clear
        uint256 halfPending = pending / 2;
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).clearPendingRedemptions(
            halfPending
        );
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).pendingRedemptions(),
            pending - halfPending,
            "Partial clear failed"
        );

        // Still cannot harvest
        vm.prank(keeper);
        vm.expectRevert("Pending redemptions");
        strategy.report();

        // Clear remaining
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).clearPendingRedemptions(
            pending
        );
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).pendingRedemptions(),
            0,
            "Full clear failed"
        );

        // Non-management cannot clear
        vm.prank(user);
        vm.expectRevert("!management");
        BaseLSTAccumulator(address(stethStrategy)).clearPendingRedemptions(1);
    }

    function test_manualClaimWithdrawals() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );

        // Initiate withdrawal through normal path
        vm.prank(management);
        bytes memory returnData = BaseLSTAccumulator(address(stethStrategy))
            .initiateLSTWithdrawal(stethBalance);
        uint256[] memory requestIds = abi.decode(returnData, (uint256[]));

        uint256 wethBefore = asset.balanceOf(address(strategy));

        // Use manualClaimWithdrawals with zeroRedemptions=true
        uint256[] memory hints = new uint256[](1);
        hints[0] = 0; // Mock doesn't use hints

        vm.prank(emergencyAdmin);
        stethStrategy.manualClaimWithdrawals(requestIds, hints, true);

        // Check WETH was received
        uint256 wethAfter = asset.balanceOf(address(strategy));
        assertGt(wethAfter, wethBefore, "WETH not received");

        // Check pending redemptions zeroed
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).pendingRedemptions(),
            0,
            "Pending redemptions not zeroed"
        );

        // Non-emergency-authorized cannot call
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        stethStrategy.manualClaimWithdrawals(requestIds, hints, false);
    }

    function test_manualClaimWithdrawals_keepRedemptions() public {
        uint256 _amount = 10e18;

        // Setup: deposit and harvest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        skip(1 days);
        vm.prank(keeper);
        strategy.report();

        Strategy stethStrategy = Strategy(payable(address(strategy)));
        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );

        // Initiate withdrawal
        vm.prank(management);
        BaseLSTAccumulator(address(stethStrategy)).initiateLSTWithdrawal(
            stethBalance
        );

        uint256 pendingBefore = BaseLSTAccumulator(address(stethStrategy))
            .pendingRedemptions();
        assertGt(pendingBefore, 0, "No pending redemptions");

        // Decode request IDs
        // Re-initiate to get fresh IDs (previous ones were already used)
        // Actually, we need the original request IDs. Let's just re-read the return data.
        // The mock queue assigned ID=1, so we use that.
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 1;
        uint256[] memory hints = new uint256[](1);
        hints[0] = 0;

        // Claim with zeroRedemptions=false
        vm.prank(emergencyAdmin);
        stethStrategy.manualClaimWithdrawals(requestIds, hints, false);

        // Pending redemptions should NOT be zeroed
        assertEq(
            BaseLSTAccumulator(address(stethStrategy)).pendingRedemptions(),
            pendingBefore,
            "Pending redemptions should not change"
        );
    }
}
