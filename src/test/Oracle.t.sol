// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Setup, ERC20} from "./utils/Setup.sol";
import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";
import {BaseLSTAccumulator} from "../BaseLSTAccumulator.sol";
import {ICurve} from "../interfaces/ICurve.sol";
import {MockWithdrawalQueue} from "./mocks/MockWithdrawalQueue.sol";

contract OracleTest is Setup {
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    address internal constant CURVE_POOL =
        0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address internal constant WITHDRAWAL_QUEUE =
        0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address internal constant STETH_WHALE =
        0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    StrategyAprOracle public oracle;
    MockWithdrawalQueue internal mockQueue;

    function setUp() public override {
        super.setUp();
        oracle = new StrategyAprOracle();
        _setUpMockWithdrawalQueue();
    }

    function test_oracleReturnsBaseAprWhenTotalAssetsIsZero() public {
        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            oracle.baseApr(),
            "not base apr"
        );
    }

    function test_oracleAnnualizesUnrealizedProfit() public {
        uint256 assets = 100e18;
        uint256 unrealizedProfit = 1e18;
        uint256 elapsed = 19 days + 7 hours;

        _depositAndReport(assets);

        skip(elapsed);
        _airdropStEth(unrealizedProfit);

        uint256 livePositionValue = _livePositionValue();
        uint256 expectedApr = _expectedApr(
            strategy.totalAssets(),
            livePositionValue,
            elapsed
        );
        assertGt(expectedApr, oracle.baseApr(), "expected apr not above base");

        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            expectedApr,
            "bad apr"
        );
        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 100e18),
            expectedApr,
            "delta should be ignored"
        );
        assertEq(
            oracle.aprAfterDebtChange(address(strategy), -100e18),
            expectedApr,
            "negative delta should be ignored"
        );
    }

    function test_oracleCountsPendingRedemptions() public {
        uint256 assets = 100e18;
        uint256 withdrawalAmount = 20e18;
        uint256 unrealizedProfit = 1e18;
        uint256 elapsed = 11 days + 3 hours;

        _depositAndReport(assets);

        vm.prank(management);
        BaseLSTAccumulator(address(strategy)).initiateLSTWithdrawal(
            withdrawalAmount
        );

        uint256 stethBalance = ERC20(tokenAddrs["STETH"]).balanceOf(
            address(strategy)
        );
        assertLt(
            stethBalance,
            strategy.totalAssets(),
            "queue did not pull steth"
        );
        assertGt(
            _livePositionValue(),
            stethBalance,
            "pending redemptions not added"
        );

        skip(elapsed);
        _airdropStEth(unrealizedProfit);

        uint256 livePositionValue = _livePositionValue();
        uint256 expectedApr = _expectedApr(
            strategy.totalAssets(),
            livePositionValue,
            elapsed
        );
        assertGt(expectedApr, oracle.baseApr(), "expected apr not above base");

        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            expectedApr,
            "pending not counted"
        );
    }

    function test_oracleReturnsBaseAprWhenUnrealizedAprIsLower() public {
        uint256 assets = 100e18;
        uint256 unrealizedProfit = 0.1e18;
        uint256 elapsed = 60 days;

        _depositAndReport(assets);

        skip(elapsed);
        _airdropStEth(unrealizedProfit);

        uint256 expectedApr = _expectedApr(
            strategy.totalAssets(),
            _livePositionValue(),
            elapsed
        );
        assertLt(expectedApr, oracle.baseApr(), "expected apr not below base");

        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            oracle.baseApr(),
            "not base apr"
        );
    }

    function test_oracleReturnsBaseAprWhenNoUnrealizedProfit() public {
        _depositAndReport(100e18);

        skip(13 days);

        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            oracle.baseApr(),
            "not base apr"
        );
    }

    function test_oracleReturnsBaseAprWhenElapsedTimeIsZero() public {
        _depositAndReport(100e18);
        _airdropStEth(1e18);

        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            oracle.baseApr(),
            "not base apr"
        );
    }

    function _depositAndReport(uint256 _amount) internal {
        _forceDirectStake(_amount);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();
    }

    function _forceDirectStake(uint256 _amount) internal {
        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSelector(
                ICurve.get_dy.selector,
                int128(0),
                int128(1),
                _amount
            ),
            abi.encode(_amount - 1)
        );
    }

    function _airdropStEth(uint256 _amount) internal {
        vm.prank(STETH_WHALE);
        ERC20(tokenAddrs["STETH"]).transfer(address(strategy), _amount);
    }

    function _livePositionValue() internal view returns (uint256) {
        return
            ERC20(tokenAddrs["STETH"]).balanceOf(address(strategy)) +
            BaseLSTAccumulator(address(strategy)).pendingRedemptions();
    }

    function _expectedApr(
        uint256 _totalAssets,
        uint256 _liveValue,
        uint256 _elapsed
    ) internal pure returns (uint256) {
        return
            ((_liveValue - _totalAssets) * SECONDS_PER_YEAR * 1e18) /
            _elapsed /
            _totalAssets;
    }

    function _setUpMockWithdrawalQueue() internal {
        mockQueue = new MockWithdrawalQueue();

        bytes memory runtimeCode = address(mockQueue).code;
        vm.etch(WITHDRAWAL_QUEUE, runtimeCode);
        vm.store(WITHDRAWAL_QUEUE, bytes32(uint256(1)), bytes32(uint256(1)));
        vm.deal(WITHDRAWAL_QUEUE, 1000 ether);
    }
}
