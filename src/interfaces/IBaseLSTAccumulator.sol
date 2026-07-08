// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

interface IBaseLSTAccumulator is IBaseHealthCheck {
    // Events
    event StakeAssetUpdated(bool indexed stakeAsset);
    event DepositLimitUpdated(uint256 indexed depositLimit);
    event ReportBufferUpdated(uint256 indexed reportBuffer);
    event MinAmountToTendUpdated(uint256 indexed minAmountToTend);
    event MaxGasPriceToTendUpdated(uint256 indexed maxGasPriceToTend);

    // View functions
    function LST() external view returns (address);
    function stakeAsset() external view returns (bool);
    function estimatedTotalAssets() external view returns (uint256);
    function depositLimit() external view returns (uint256);
    function reportBuffer() external view returns (uint256);
    function minAmountToTend() external view returns (uint256);
    function maxGasPriceToTend() external view returns (uint256);
    function pendingRedemptions() external view returns (uint256);

    // Management functions
    function setStakeAsset(bool _stakeAsset) external;
    function setDepositLimit(uint256 _limit) external;
    function setReportBuffer(uint256 _reportBuffer) external;
    function setMinAmountToTend(uint256 _minAmountToTend) external;
    function setMaxGasPriceToTend(uint256 _maxGasPriceToTend) external;

    // Manual operations
    function manualSwapToAsset(uint256 _amount, uint256 _minOut) external;
    function manualStake(uint256 _amount) external;
    function initiateLSTWithdrawal(uint256 _amount) external returns (bytes memory returnData);
    function claimLSTWithdrawal(bytes memory _claimData) external returns (uint256);
    function clearPendingRedemptions(uint256 _amount) external;
}
