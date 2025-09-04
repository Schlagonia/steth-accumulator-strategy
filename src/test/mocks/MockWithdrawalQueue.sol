// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWithdrawalQueue {
    mapping(uint256 => uint256) public withdrawalAmounts;
    uint256 public nextRequestId = 1;

    function requestWithdrawals(
        uint256[] calldata _amounts,
        address _owner
    ) external returns (uint256[] memory requestIds) {
        requestIds = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; i++) {
            uint256 requestId = nextRequestId++;
            withdrawalAmounts[requestId] = _amounts[i];
            requestIds[i] = requestId;

            // Transfer stETH from caller
            ERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84).transferFrom(
                msg.sender,
                address(this),
                _amounts[i]
            );
        }
    }

    function claimWithdrawal(uint256 _requestId) external {
        uint256 amount = withdrawalAmounts[_requestId];
        require(amount > 0, "Invalid request");

        // Send ETH to caller
        withdrawalAmounts[_requestId] = 0;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    // Allow receiving stETH
    receive() external payable {}
}
