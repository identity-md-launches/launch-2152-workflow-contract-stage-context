// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockerTreasury} from "../src/LockerTreasury.sol";
import {LockerFarmFactory} from "../src/LockerFarmFactory.sol";
import {LockerFarm} from "../src/LockerFarm.sol";

/// @title DeployLocker
/// @notice Reproduces, for local testing and review, the deployment the IMD launch performs:
///         LaunchToken, then LockerTreasury, LockerFarmFactory and the LOCKER farm in dependency
///         order with the launch owner as every admin argument.
/// @dev This script is documentation of the constructor wiring. It never runs in the real launch:
///      IMD's deployer launches the attested bytecode through ProjectFactory. `run()` only reads the
///      owner from `LOCKER_OWNER`; tests call `deploy(owner)` directly and never touch the environment.
contract DeployLocker is Script {
    struct Deployment {
        LaunchToken token;
        LockerTreasury treasury;
        LockerFarmFactory factory;
        LockerFarm lockerFarm;
    }

    function run() external returns (Deployment memory d) {
        address owner_ = vm.envAddress("LOCKER_OWNER");
        vm.startBroadcast();
        d = deploy(owner_);
        vm.stopBroadcast();
    }

    /// @notice Deploys the full contract set with `owner_` as owner, emissions manager and guardian.
    function deploy(address owner_) public returns (Deployment memory d) {
        d.token = new LaunchToken();
        d.treasury = new LockerTreasury(owner_, address(d.token));
        d.factory = new LockerFarmFactory(owner_, address(d.token), address(d.treasury));
        d.lockerFarm = new LockerFarm(address(d.token), address(d.token), address(d.treasury), owner_);
    }
}
