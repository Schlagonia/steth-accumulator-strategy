// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IBaseLSTAccumulator} from "./IBaseLSTAccumulator.sol";

interface IStrategyInterface is IBaseLSTAccumulator {
    // stETH-specific functions

    function referral() external view returns (address);
    function setReferral(address _referral) external;
}
