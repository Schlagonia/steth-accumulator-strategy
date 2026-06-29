// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IStrategyInterface} from "./IStrategyInterface.sol";
import {IWstETH} from "./IWstETH.sol";

interface IStrategy4626Interface is IStrategyInterface {
    function vault() external view returns (IERC4626);
    function wstETH() external view returns (IWstETH);
    function balanceOfWstETH() external view returns (uint256);
    function valueOfWstETH() external view returns (uint256);
    function manualRedeem(uint256 _amount) external;
    function manualUnwrap(uint256 _amount) external;
}
