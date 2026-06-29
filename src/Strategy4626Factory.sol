// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strategy4626} from "./Strategy4626.sol";
import {IStrategy4626Interface} from "./interfaces/IStrategy4626Interface.sol";

contract Strategy4626Factory {
    /// @notice Revert message for when a strategy has already been deployed.
    error AlreadyDeployed(address _strategy);

    event NewStrategy4626(address indexed strategy, address indexed vault);

    address public immutable ASSET;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;
    address public emergencyAdmin;

    /// @notice Track the deployments. vault => strategy
    mapping(address => address) public deployments;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin,
        address _asset
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
        ASSET = _asset;
    }

    /**
     * @notice Deploy a new Strategy4626.
     * @param _vault The ERC4626 vault for the strategy to use.
     * @return . The address of the new strategy.
     */
    function newStrategy4626(address _vault) external returns (address) {
        if (deployments[_vault] != address(0)) {
            revert AlreadyDeployed(deployments[_vault]);
        }

        string memory _name = string(abi.encodePacked("stETH ", ERC20(_vault).symbol(), " Accumulator"));

        // We need to use the custom interface with the
        // tokenized strategies available setters.
        IStrategy4626Interface newStrategy = IStrategy4626Interface(address(new Strategy4626(ASSET, _name, _vault)));

        newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        newStrategy.setKeeper(keeper);

        newStrategy.setPendingManagement(management);

        newStrategy.setEmergencyAdmin(emergencyAdmin);

        newStrategy.setPerformanceFee(0);

        newStrategy.setProfitMaxUnlockTime(0);

        emit NewStrategy4626(address(newStrategy), _vault);

        deployments[_vault] = address(newStrategy);
        return address(newStrategy);
    }

    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    function isDeployedStrategy(address _strategy) external view returns (bool) {
        address _vault = address(IStrategy4626Interface(_strategy).vault());
        return deployments[_vault] == _strategy;
    }
}
