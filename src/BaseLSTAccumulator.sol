// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Base LST Accumulator
/// @author yearn.fi
/// @notice Abstract base contract for LST (Liquid Staking Token) accumulation strategies
abstract contract BaseLSTAccumulator is BaseHealthCheck {
    using SafeERC20 for ERC20;

    // Events
    event StakeAssetUpdated(bool indexed stakeAsset);
    event DepositLimitUpdated(uint256 indexed depositLimit);
    event ReportBufferUpdated(uint256 indexed reportBuffer);
    event MinAmountToTendUpdated(uint256 indexed minAmountToTend);
    event MaxGasPriceToTendUpdated(uint256 indexed maxGasPriceToTend);

    uint256 internal constant WAD = 1e18;

    uint256 internal constant ASSET_DUST = 1000;

    address public immutable LST;

    // Common parameters for all LST strategies
    bool public stakeAsset; // If true, the strategy will stake asset to LST during deposits

    uint256 public depositLimit;

    uint256 public reportBuffer;

    uint256 public minAmountToTend;

    uint256 public maxGasPriceToTend;

    uint256 public pendingRedemptions;

    constructor(address _asset, string memory _name, address _lst) BaseHealthCheck(_asset, _name) {
        LST = _lst;

        stakeAsset = true;
        emit StakeAssetUpdated(true);

        // Default parameters - can be overridden in child constructors
        depositLimit = type(uint256).max;
        emit DepositLimitUpdated(type(uint256).max);

        minAmountToTend = type(uint256).max;
        emit MinAmountToTendUpdated(type(uint256).max);

        maxGasPriceToTend = 10e9;
        emit MaxGasPriceToTendUpdated(10e9);

        allowed[address(this)] = true;
    }

    /*//////////////////////////////////////////////////////////////
                VIRTUAL FUNCTIONS - MUST BE IMPLEMENTED
    //////////////////////////////////////////////////////////////*/

    /// @notice Stake asset to LST using the most optimal route
    /// @param _amount Amount of asset to stake
    function _stake(uint256 _amount) internal virtual;

    /// @notice Manually swap LST back to asset
    /// @param _amount Amount of LST to swap
    function _swapLSTToAsset(uint256 _amount, uint256 _minOut) internal virtual;

    /// @notice Initiate LST withdrawal through Lido queue for 1:1 redemption
    /// @dev Should revert if the withdrawal request is not successful
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return returnData Return data from the withdrawal request
    function _initiateLSTWithdrawal(uint256 _amount) internal virtual returns (bytes memory returnData);

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimData The claim data from the withdrawal request
    /// @return _redeemedAmount Amount of LST claimed
    function _claimLSTWithdrawal(bytes memory _claimData) internal virtual returns (uint256 _redeemedAmount);

    /// @notice Claim and sell rewards
    function _claimAndSellRewards() internal virtual {}

    /// @notice Get the deposit limit
    /// @dev Can be overridden by child contracts to implement custom deposit limits
    /// @return _depositLimit The deposit limit
    function _depositLimit() internal view virtual returns (uint256) {
        uint256 _estimatedTotalAssets = estimatedTotalAssets();
        uint256 _limit = depositLimit;
        if (_estimatedTotalAssets < _limit) {
            return _limit - _estimatedTotalAssets;
        }
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                INTERNAL BASE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal virtual override {
        if (stakeAsset && _amount > ASSET_DUST) {
            _stake(_amount);
        }
    }

    function _freeFunds(
        uint256 /*_amount*/
    )
        internal
        virtual
        override
    {
        // Do nothing - no automatic unstaking
        // Management must manually swap LST to asset if needed
    }

    function availableDepositLimit(address _owner) public view virtual override returns (uint256) {
        return Math.min(super.availableDepositLimit(_owner), _depositLimit());
    }

    function availableWithdrawLimit(
        address /*_owner*/
    )
        public
        view
        virtual
        override
        returns (uint256)
    {
        // Only allow liquid withdrawals (available asset)
        return balanceOfAsset();
    }

    function _harvestAndReport() internal virtual override returns (uint256 _totalAssets) {
        require(pendingRedemptions == 0, "Pending redemptions");

        _claimAndSellRewards();

        // Stake any loose asset
        _stake(Math.min(balanceOfAsset(), availableDepositLimit(address(this))));

        // Simple accounting: Asset + LST (assuming LST rebases or maintains peg)
        _totalAssets = estimatedTotalAssets();
    }

    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        uint256 lstBalance = balanceOfLST();
        if (lstBalance == 0) return;

        _amount = Math.min(_amount, lstBalance);
        uint256 _amountOut = (_amount * (MAX_BPS - reportBuffer)) / MAX_BPS;

        _swapLSTToAsset(_amount, _amountOut);
    }

    function _tend(uint256 _totalIdle) internal virtual override {
        _stake(_totalIdle);
    }

    function _tendTrigger() internal view virtual override returns (bool) {
        uint256 toDeploy = Math.min(balanceOfAsset(), _depositLimit());
        return toDeploy > minAmountToTend && block.basefee <= maxGasPriceToTend;
    }

    /*//////////////////////////////////////////////////////////////
                EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function estimatedTotalAssets() public view virtual returns (uint256) {
        return balanceOfAsset() + (((valueOfLST() + pendingRedemptions) * (MAX_BPS - reportBuffer)) / MAX_BPS);
    }

    function balanceOfAsset() internal view virtual returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function balanceOfLST() internal view virtual returns (uint256) {
        return ERC20(LST).balanceOf(address(this));
    }

    // @notice Default to 1:1 value of LST
    function valueOfLST() internal view virtual returns (uint256) {
        return balanceOfLST();
    }

    /*//////////////////////////////////////////////////////////////
                MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setReportBuffer(uint256 _reportBuffer) external virtual onlyManagement {
        require(_reportBuffer <= MAX_BPS, "Invalid report buffer");
        reportBuffer = _reportBuffer;
        emit ReportBufferUpdated(_reportBuffer);
    }

    /// @notice Set whether the strategy will stake asset to LST during harvest
    function setStakeAsset(bool _stakeAsset) external virtual onlyManagement {
        stakeAsset = _stakeAsset;
        emit StakeAssetUpdated(_stakeAsset);
    }

    /// @notice Set the maximum amount that can be staked in a single harvest
    function setDepositLimit(uint256 _limit) external virtual onlyManagement {
        depositLimit = _limit;
        emit DepositLimitUpdated(_limit);
    }

    /// @notice Set the minimum amount of asset to tend
    function setMinAmountToTend(uint256 _minAmountToTend) external virtual onlyManagement {
        minAmountToTend = _minAmountToTend;
        emit MinAmountToTendUpdated(_minAmountToTend);
    }

    /// @notice Set the maximum gas price to tend
    function setMaxGasPriceToTend(uint256 _maxGasPriceToTend) external virtual onlyManagement {
        maxGasPriceToTend = _maxGasPriceToTend;
        emit MaxGasPriceToTendUpdated(_maxGasPriceToTend);
    }

    /// @notice Manually swap LST to asset
    /// @dev Any losses realized during the swap will need a "report" to be realized.
    /// @param _amount Amount of LST to swap
    function manualSwapToAsset(uint256 _amount, uint256 _minOut) external virtual onlyManagement {
        _amount = Math.min(_amount, valueOfLST());
        require(_amount > 0, "!amount");
        require(_minOut > 0, "!minOut");

        _swapLSTToAsset(_amount, _minOut);
    }

    /// @notice Stake available asset to LST
    /// @param _amount Amount of asset to stake
    function manualStake(uint256 _amount) external virtual onlyManagement {
        _amount = Math.min(_amount, balanceOfAsset());
        require(_amount > 0, "!amount");
        _stake(_amount);
    }

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return returnData Return data from the withdrawal request
    function initiateLSTWithdrawal(uint256 _amount) external virtual onlyManagement returns (bytes memory returnData) {
        _amount = Math.min(_amount, valueOfLST());
        require(_amount > 0, "!amount");
        pendingRedemptions += _amount;
        return _initiateLSTWithdrawal(_amount);
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimData The claim data from the withdrawal request
    /// @return _amount Amount of LST claimed
    function claimLSTWithdrawal(bytes memory _claimData) external virtual onlyKeepers returns (uint256) {
        uint256 _redeemedAmount = _claimLSTWithdrawal(_claimData);
        pendingRedemptions = _redeemedAmount >= pendingRedemptions ? 0 : pendingRedemptions - _redeemedAmount;
        return _redeemedAmount;
    }

    /// @notice Clear pending redemptions in emergency
    /// @dev This should only be used in extreme scenarios when there are
    ///    issues with the redemtion process in order to "unstick" a strategy.
    ///    Using this will cause losses to potentially be realized during the next report
    function clearPendingRedemptions(uint256 _amount) external virtual onlyManagement {
        pendingRedemptions = _amount >= pendingRedemptions ? 0 : pendingRedemptions - _amount;
    }
}
