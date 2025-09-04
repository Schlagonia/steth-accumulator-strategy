// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseLSTAccumulator} from "./BaseLSTAccumulator.sol";
import {IQueue} from "./interfaces/IQueue.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ICurve} from "./interfaces/ICurve.sol";
import {ISTETH} from "./interfaces/ISTETH.sol";

/// @title stETH Accumulator Strategy
/// @author yearn.fi
/// @notice Yearn V3 strategy for accumulating stETH through optimal staking routes
contract Strategy is BaseLSTAccumulator {
    using SafeERC20 for ERC20;

    // stETH specific constants
    address internal constant WITHDRAWAL_QUEUE =
        0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1; // stETH withdrawal queue

    address internal constant CURVE_POOL =
        0xDC24316b9AE028F1497c275EB9192a3Ea0f67022; // Curve ETH/stETH pool

    int128 internal constant ASSET_ID = 0; // ETH index in Curve pool

    int128 internal constant LST_ID = 1; // stETH index in Curve pool

    address public referral;

    constructor(
        address _asset,
        string memory _name
    )
        BaseLSTAccumulator(
            _asset,
            _name,
            0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
        )
    {
        // Approve Curve pool for asset (WETH) and LST (stETH)
        asset.safeApprove(CURVE_POOL, type(uint256).max);
        ERC20(LST).safeApprove(CURVE_POOL, type(uint256).max);

        // Approve stETH withdrawal queue
        ERC20(LST).safeApprove(WITHDRAWAL_QUEUE, type(uint256).max);
    }

    receive() external payable {}

    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        if (ISTETH(LST).isStakingPaused()) {
            return 0;
        }
        return super.availableDepositLimit(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                REQUIRED VIRTUAL FUNCTION IMPLEMENTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stake ETH to stETH using the most optimal route
    /// @param _amount Amount of WETH to stake
    function _stake(uint256 _amount) internal override {
        // Convert WETH to ETH
        IWETH(address(asset)).withdraw(_amount);

        // Check if Curve swap gives better than 1:1 rate
        if (ICurve(CURVE_POOL).get_dy(ASSET_ID, LST_ID, _amount) > _amount) {
            // Swap through Curve for better rate
            ICurve(CURVE_POOL).exchange{value: _amount}(
                ASSET_ID,
                LST_ID,
                _amount,
                _amount // Minimum 1:1
            );
        } else {
            // Stake directly with Lido for 1:1
            ISTETH(LST).submit{value: _amount}(referral);
        }
    }

    /// @notice Swap stETH to WETH through Curve
    /// @param _amount Amount of stETH to swap
    function _swapLSTToAsset(
        uint256 _amount,
        uint256 _minOut
    ) internal virtual override {
        // Swap stETH for ETH through Curve
        ICurve(CURVE_POOL).exchange(LST_ID, ASSET_ID, _amount, _minOut);

        // Convert received ETH to WETH
        IWETH(address(asset)).deposit{value: address(this).balance}();
    }

    /*//////////////////////////////////////////////////////////////
                STETH SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return returnData Return data from the withdrawal request
    function _initiateLSTWithdrawal(
        uint256 _amount
    ) internal virtual override returns (bytes memory returnData) {
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _amount;

        uint256[] memory requestIds = IQueue(WITHDRAWAL_QUEUE)
            .requestWithdrawals(_amounts, address(this));

        return abi.encode(requestIds);
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimData The claim data from the withdrawal request
    function _claimLSTWithdrawal(
        bytes memory _claimData
    ) internal virtual override returns (uint256 _redeemedAmount) {
        uint256 _requestId = abi.decode(_claimData, (uint256));

        uint256 preBalance = address(this).balance;
        IQueue(WITHDRAWAL_QUEUE).claimWithdrawal(_requestId);
        _redeemedAmount = address(this).balance - preBalance;

        // Convert received ETH to WETH
        IWETH(address(asset)).deposit{value: _redeemedAmount}();
    }

    function setReferral(address _referral) external virtual onlyManagement {
        referral = _referral;
    }
}
