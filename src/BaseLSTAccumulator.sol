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
    event OpenDepositsUpdated(bool indexed openDeposits);
    event AllowedUpdated(address indexed user, bool indexed allowed);
    event DepositLimitUpdated(uint256 indexed depositLimit);

    uint256 internal constant WAD = 1e18;

    uint256 internal constant ASSET_DUST = 1000;

    address public immutable LST;

    // Common parameters for all LST strategies
    bool public stakeAsset; // If true, the strategy will stake asset to LST during deposits

    uint256 public depositLimit;

    uint256 public pendingRedemptions;

    // Access control
    bool public openDeposits; // If the strategy is open for any depositors

    mapping(address => bool) public allowed; // Addresses allowed to deposit when not open

    constructor(
        address _asset,
        string memory _name,
        address _lst
    ) BaseHealthCheck(_asset, _name) {
        LST = _lst;

        stakeAsset = true;
        emit StakeAssetUpdated(true);

        // Default parameters - can be overridden in child constructors
        depositLimit = 2 ** 256 - 1;
        emit DepositLimitUpdated(2 ** 256 - 1);

        openDeposits = false;
        emit OpenDepositsUpdated(false);
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
    function _initiateLSTWithdrawal(
        uint256 _amount
    ) internal virtual returns (bytes memory returnData);

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimData The claim data from the withdrawal request
    /// @return _redeemedAmount Amount of LST claimed
    function _claimLSTWithdrawal(
        bytes memory _claimData
    ) internal virtual returns (uint256 _redeemedAmount);

    /// @notice Claim and sell rewards
    function _claimAndSellRewards() internal virtual {}

    /*//////////////////////////////////////////////////////////////
                INTERNAL BASE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal virtual override {
        if (stakeAsset && _amount > ASSET_DUST) {
            _stake(_amount);
        }
    }

    function _freeFunds(uint256 /*_amount*/) internal virtual override {
        // Do nothing - no automatic unstaking
        // Management must manually swap LST to asset if needed
    }

    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        if (openDeposits || allowed[_owner]) {
            uint256 _estimatedTotalAssets = estimatedTotalAssets();
            uint256 _depositLimit = depositLimit;
            if (_estimatedTotalAssets < _depositLimit) {
                return _depositLimit - _estimatedTotalAssets;
            }
            return 0;
        }
        return 0;
    }

    function availableWithdrawLimit(
        address /*_owner*/
    ) public view virtual override returns (uint256) {
        // Only allow liquid withdrawals (available asset)
        return balanceOfAsset();
    }

    function _harvestAndReport()
        internal
        virtual
        override
        returns (uint256 _totalAssets)
    {
        require(pendingRedemptions == 0, "Pending redemptions");

        _claimAndSellRewards();

        // Stake any loose asset if not shutdown
        _deployFunds(balanceOfAsset());

        // Simple accounting: Asset + LST (assuming LST rebases or maintains peg)
        _totalAssets = estimatedTotalAssets();
    }

    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        uint256 lstBalance = balanceOfLST();
        if (lstBalance == 0) return;

        _swapLSTToAsset(Math.min(_amount, lstBalance), 0);
    }

    /*//////////////////////////////////////////////////////////////
                EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function estimatedTotalAssets() public view virtual returns (uint256) {
        return balanceOfAsset() + valueOfLST();
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

    /// @notice Set whether the strategy will stake asset to LST during harvest
    function setStakeAsset(bool _stakeAsset) external virtual onlyManagement {
        stakeAsset = _stakeAsset;
        emit StakeAssetUpdated(_stakeAsset);
    }

    /// @notice Set the maximum amount that can be staked in a single harvest
    function setDepositLimit(
        uint256 _depositLimit
    ) external virtual onlyManagement {
        depositLimit = _depositLimit;
        emit DepositLimitUpdated(_depositLimit);
    }

    /// @notice Set whether the strategy is open for deposits
    function setOpenDeposits(
        bool _openDeposits
    ) external virtual onlyEmergencyAuthorized {
        openDeposits = _openDeposits;
        emit OpenDepositsUpdated(_openDeposits);
    }

    /// @notice Set or update an address's whitelist status
    function setAllowed(
        address _address,
        bool _allowed
    ) external virtual onlyEmergencyAuthorized {
        allowed[_address] = _allowed;
        emit AllowedUpdated(_address, _allowed);
    }

    /// @notice Manually swap LST to asset
    /// @param _amount Amount of LST to swap
    function manualSwapToAsset(
        uint256 _amount,
        uint256 _minOut
    ) external virtual onlyManagement {
        _amount = Math.min(_amount, balanceOfLST());
        require(_amount > 0, "!amount");

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
    function initiateLSTWithdrawal(
        uint256 _amount
    ) external virtual onlyManagement returns (bytes memory returnData) {
        _amount = Math.min(_amount, balanceOfLST());
        require(_amount > 0, "!amount");
        pendingRedemptions += _amount;
        return _initiateLSTWithdrawal(_amount);
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimData The claim data from the withdrawal request
    /// @return _amount Amount of LST claimed
    function claimLSTWithdrawal(
        bytes memory _claimData
    ) external virtual onlyManagement returns (uint256) {
        uint256 _redeemedAmount = _claimLSTWithdrawal(_claimData);
        pendingRedemptions -= _redeemedAmount;
        return _redeemedAmount;
    }
}
