// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strategy} from "./Strategy.sol";
import {IWstETH} from "./interfaces/IWstETH.sol";

/// @title stETH Accumulator With ERC-4626 Vault
/// @author yearn.fi
contract Strategy4626 is Strategy {
    using SafeERC20 for *;

    IWstETH public constant wstETH =
        IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    IERC4626 public immutable vault;

    constructor(
        address _asset,
        string memory _name,
        address _vault
    ) Strategy(_asset, _name) {
        require(IERC4626(_vault).asset() == address(wstETH), "wrong vault");

        vault = IERC4626(_vault);

        ERC20(LST).forceApprove(address(wstETH), type(uint256).max);
        wstETH.forceApprove(_vault, type(uint256).max);
    }

    function _stake(uint256 _amount) internal virtual override {
        super._stake(_amount);

        uint256 stethBalance = ERC20(LST).balanceOf(address(this));
        if (stethBalance == 0) return;

        uint256 wstETHBalance = wstETH.wrap(stethBalance);
        // Can round to 0 if stethBalance is too small
        if (wstETHBalance == 0) return;

        vault.deposit(wstETHBalance, address(this));
    }

    function _swapLSTToAsset(
        uint256 _amount,
        uint256 _minOut
    ) internal virtual override {
        _freeStETH(_amount);
        super._swapLSTToAsset(
            Math.min(_amount, ERC20(LST).balanceOf(address(this))),
            _minOut
        );
    }

    function _initiateLSTWithdrawal(
        uint256 _amount
    ) internal virtual override returns (bytes memory returnData) {
        _freeStETH(_amount);
        require(ERC20(LST).balanceOf(address(this)) >= _amount, "!available");
        return super._initiateLSTWithdrawal(_amount);
    }

    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        uint256 superLimit = super.availableDepositLimit(_owner);
        if (superLimit == 0) return 0;

        uint256 maxDeposit = vault.maxDeposit(address(this));
        if (maxDeposit == type(uint256).max) return superLimit;

        return Math.min(superLimit, _stETHValue(maxDeposit));
    }

    function balanceOfWstETH() public view virtual returns (uint256) {
        return wstETH.balanceOf(address(this));
    }

    function valueOfWstETH() public view virtual returns (uint256) {
        return
            _stETHValue(
                balanceOfWstETH() +
                    vault.convertToAssets(vault.balanceOf(address(this)))
            );
    }

    function balanceOfLST() internal view virtual override returns (uint256) {
        return ERC20(LST).balanceOf(address(this)) + valueOfWstETH();
    }

    function _freeStETH(uint256 _amount) internal {
        uint256 stethBalance = ERC20(LST).balanceOf(address(this));
        if (stethBalance >= _amount) return;

        uint256 neededWstETH = wstETH.getWstETHByStETH(_amount) + 1;

        uint256 wrappedBalance = balanceOfWstETH();
        if (wrappedBalance < neededWstETH) {
            // Redeem the difference up to max redeem.
            uint256 shares = Math.min(
                vault.previewWithdraw(neededWstETH - wrappedBalance),
                vault.maxRedeem(address(this))
            );

            if (shares > 0) {
                wrappedBalance += vault.redeem(
                    shares,
                    address(this),
                    address(this)
                );
            }
        }

        wstETH.unwrap(wrappedBalance);
    }

    function _stETHValue(uint256 _amount) internal view returns (uint256) {
        if (_amount == 0) return 0;
        return wstETH.getStETHByWstETH(_amount);
    }

    function manualRedeem(uint256 _amount) external onlyEmergencyAuthorized {
        _amount = Math.min(_amount, vault.balanceOf(address(this)));
        if (_amount == 0) return;

        vault.redeem(_amount, address(this), address(this));
    }

    function manualUnwrap(uint256 _amount) external onlyEmergencyAuthorized {
        _amount = Math.min(_amount, balanceOfWstETH());
        if (_amount == 0) return;

        wstETH.unwrap(_amount);
    }
}
