// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";

contract StrategyAprOracle is AprOracleBase {
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    uint256 public baseApr = 2.5e16;

    constructor() AprOracleBase("stETH Accumulator APR Oracle", msg.sender) {}

    /**
     * @notice Estimate the live APR the strategy would report right now.
     * @dev `_delta` is intentionally ignored. This oracle is based on the
     * strategy's current live stETH exposure plus pending redemptions vs the
     * last reported `totalAssets`.
     *
     * APR is returned as 1e18 where 10% = 1e17.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 /*_delta*/
    ) external view override returns (uint256) {
        IStrategyInterface strategy = IStrategyInterface(_strategy);
        uint256 _baseApr = baseApr;

        uint256 totalAssets = strategy.totalAssets();
        if (totalAssets == 0) return _baseApr;

        uint256 livePositionValue = ERC20(strategy.LST()).balanceOf(_strategy) +
            strategy.pendingRedemptions();
        if (livePositionValue <= totalAssets) return _baseApr;

        uint256 lastReport = strategy.lastReport();
        if (block.timestamp <= lastReport) return _baseApr;

        uint256 elapsed = block.timestamp - lastReport;
        uint256 unrealizedProfit = livePositionValue - totalAssets;
        uint256 unrealizedApr =
            (unrealizedProfit * SECONDS_PER_YEAR * 1e18) /
            elapsed /
            totalAssets;

        return unrealizedApr > _baseApr ? unrealizedApr : _baseApr;
    }

    function setBaseApr(uint256 _baseApr) external virtual onlyGovernance {
        baseApr = _baseApr;
    }
}
