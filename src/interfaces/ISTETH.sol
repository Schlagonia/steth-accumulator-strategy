// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISTETH is IERC20 {
    function submit(address) external payable returns (uint256);
    function isStakingPaused() external view returns (bool);
}
