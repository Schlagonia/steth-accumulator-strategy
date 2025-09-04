// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

interface IBaseLSTAccumulator is IBaseHealthCheck {
    // Events
    event StakeAssetUpdated(bool stakeAsset);
    event DepositLimitUpdated(uint256 depositLimit);
    event OpenDepositsUpdated(bool openDeposits);
    event AllowedUpdated(address indexed user, bool allowed);

    // View functions
    function LST() external view returns (address);
    function stakeAsset() external view returns (bool);
    function balanceOfAsset() external view returns (uint256);
    function balanceOfLST() external view returns (uint256);
    function valueOfLST() external view returns (uint256);
    function estimatedTotalAssets() external view returns (uint256);
    function depositLimit() external view returns (uint256);
    function openDeposits() external view returns (bool);
    function allowed(address) external view returns (bool);
    function pendingRedemptions() external view returns (uint256);

    // Management functions
    function setStakeAsset(bool _stakeAsset) external;
    function setDepositLimit(uint256 _depositLimit) external;
    function setOpenDeposits(bool _openDeposits) external;
    function setAllowed(address _address, bool _allowed) external;

    // Manual operations
    function manualSwapToAsset(uint256 _amount, uint256 _minOut) external;
    function manualStake(uint256 _amount) external;
    function initiateLSTWithdrawal(
        uint256 _amount
    ) external returns (bytes memory returnData);
    function claimLSTWithdrawal(
        bytes memory _claimData
    ) external returns (uint256);
}
