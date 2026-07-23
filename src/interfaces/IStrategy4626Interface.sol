// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IStrategyInterface} from "./IStrategyInterface.sol";
import {IWstETH} from "./IWstETH.sol";

interface IStrategy4626Interface is IStrategyInterface {
    event MaxLossUpdated(uint256 indexed maxLoss);

    function vault() external view returns (IStrategyInterface);
    function wstETH() external view returns (IWstETH);
    function maxLoss() external view returns (uint256);
    function balanceOfWstETH() external view returns (uint256);
    function valueOfWstETH() external view returns (uint256);
    function setMaxLoss(uint256 _maxLoss) external;
    function manualRedeem(uint256 _amount) external;
    function manualUnwrap(uint256 _amount) external;
}
