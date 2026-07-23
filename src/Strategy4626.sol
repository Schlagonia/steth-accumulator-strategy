// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strategy} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";
import {IWstETH} from "./interfaces/IWstETH.sol";

/// @title stETH Accumulator With ERC-4626 Vault
/// @author yearn.fi
contract Strategy4626 is Strategy {
    using SafeERC20 for *;

    event MaxLossUpdated(uint256 indexed maxLoss);

    IWstETH public constant wstETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    IStrategyInterface public immutable vault;

    /// @notice Maximum loss accepted when redeeming vault shares, in basis points.
    uint256 public maxLoss;

    constructor(address _asset, string memory _name, address _vault) Strategy(_asset, _name) {
        require(IStrategyInterface(_vault).asset() == address(wstETH), "wrong vault");

        vault = IStrategyInterface(_vault);

        ERC20(LST).forceApprove(address(wstETH), type(uint256).max);
        wstETH.forceApprove(_vault, type(uint256).max);
    }

    function _stake(uint256 _amount) internal virtual override {
        super._stake(_amount);

        uint256 stethBalance = balanceOfLST();
        if (stethBalance > 0) {
            wstETH.wrap(stethBalance);
        }

        uint256 wstETHBalance = balanceOfWstETH();
        // Can round to 0 if stethBalance is too small
        if (wstETHBalance == 0) return;

        vault.deposit(wstETHBalance, address(this));
    }

    function _swapLSTToAsset(uint256 _amount, uint256 _minOut) internal virtual override {
        _freeStETH(_amount);
        super._swapLSTToAsset(Math.min(_amount, balanceOfLST()), _minOut);
    }

    function _initiateLSTWithdrawal(uint256 _amount) internal virtual override returns (bytes memory returnData) {
        _freeStETH(_amount);
        require(balanceOfLST() >= _amount, "!available");
        return super._initiateLSTWithdrawal(_amount);
    }

    function _depositLimit() internal view virtual override returns (uint256) {
        uint256 vaultLimit = vault.maxDeposit(address(this));
        if (vaultLimit == type(uint256).max) return super._depositLimit();

        return Math.min(super._depositLimit(), _stETHValue(vaultLimit));
    }

    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        _freeStETH(Math.min(_amount, valueOfLST()));
        super._emergencyWithdraw(_amount);
    }

    function balanceOfWstETH() public view virtual returns (uint256) {
        return wstETH.balanceOf(address(this));
    }

    function valueOfWstETH() public view virtual returns (uint256) {
        return _stETHValue(balanceOfWstETH() + vault.convertToAssets(vault.balanceOf(address(this))));
    }

    function valueOfLST() internal view virtual override returns (uint256) {
        return balanceOfLST() + valueOfWstETH();
    }

    function _freeStETH(uint256 _amount) internal {
        uint256 stethBalance = balanceOfLST();
        if (stethBalance >= _amount) return;

        // Add two wei to cover double rounding across stETH->wstETH conversion and unwrap.
        uint256 neededWstETH = wstETH.getWstETHByStETH(_amount - stethBalance) + 2;

        uint256 wrappedBalance = balanceOfWstETH();
        if (wrappedBalance < neededWstETH) {
            // Redeem the difference up to max redeem.
            uint256 shares =
                Math.min(vault.previewWithdraw(neededWstETH - wrappedBalance), vault.maxRedeem(address(this)));

            if (shares > 0) {
                wrappedBalance += vault.redeem(shares, address(this), address(this), maxLoss);
            }
        }

        if (wrappedBalance > 0) {
            wstETH.unwrap(wrappedBalance);
        }
    }

    function _stETHValue(uint256 _amount) internal view returns (uint256) {
        if (_amount == 0) return 0;
        return wstETH.getStETHByWstETH(_amount);
    }

    /// @notice Set the maximum loss accepted when redeeming vault shares.
    /// @param _maxLoss Maximum loss in basis points.
    function setMaxLoss(uint256 _maxLoss) external virtual onlyManagement {
        require(_maxLoss <= MAX_BPS, "Invalid max loss");

        maxLoss = _maxLoss;
        emit MaxLossUpdated(_maxLoss);
    }

    function manualRedeem(uint256 _amount) external onlyEmergencyAuthorized {
        _amount = Math.min(_amount, vault.balanceOf(address(this)));
        if (_amount == 0) return;

        vault.redeem(_amount, address(this), address(this), maxLoss);
    }

    function manualUnwrap(uint256 _amount) external onlyEmergencyAuthorized {
        _amount = Math.min(_amount, balanceOfWstETH());
        if (_amount == 0) return;

        wstETH.unwrap(_amount);
    }
}
