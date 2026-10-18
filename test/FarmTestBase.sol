// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {LockerTreasury} from "../src/LockerTreasury.sol";
import {LockerFarmFactory} from "../src/LockerFarmFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Shared fixture: the launch token, a Treasury, a factory, an IMD-like mock and two farms
///      (one staking the mock, one staking LOCKER itself). The launch owner holds every role.
abstract contract FarmTestBase is Test {
    address internal constant OWNER = address(0xDEA11b3A70b77134424d436f6eb455f1Abbd4449);
    address internal constant FACTORY_DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    uint256 internal constant EPOCH = 30 days;

    LaunchToken internal locker;
    MockERC20 internal imd;
    LockerTreasury internal treasury;
    LockerFarmFactory internal factory;
    LockerFarm internal imdFarm;
    LockerFarm internal lockerFarm;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vm.prank(FACTORY_DEPLOYER);
        locker = new LaunchToken();
        imd = new MockERC20("IMD", "IMD");
        treasury = new LockerTreasury(OWNER, address(locker));
        factory = new LockerFarmFactory(OWNER, address(locker), address(treasury));
        lockerFarm = new LockerFarm(address(locker), address(locker), address(treasury), OWNER);
        vm.prank(OWNER);
        imdFarm = LockerFarm(factory.createFarm(address(imd), OWNER));

        // The factory's supply stands in for the launch split: the owner gets a working balance.
        vm.prank(FACTORY_DEPLOYER);
        locker.transfer(OWNER, 600_000_000 ether);
    }

    function _giveImd(address to, uint256 amount) internal {
        imd.mint(to, amount);
        vm.prank(to);
        imd.approve(address(imdFarm), type(uint256).max);
    }

    function _giveLocker(address to, uint256 amount) internal {
        vm.prank(OWNER);
        locker.transfer(to, amount);
        vm.prank(to);
        locker.approve(address(lockerFarm), type(uint256).max);
    }

    function _deposit(LockerFarm farm, address who, uint256 amount) internal {
        vm.prank(who);
        farm.deposit(amount);
    }

    /// @dev Moves time past the fee-eligibility delay so every stake deposited so far shares fees.
    function _matureStakes() internal {
        vm.warp(block.timestamp + 2 * 1 days);
    }

    function _withdraw(LockerFarm farm, address who, uint256 amount) internal {
        vm.prank(who);
        farm.withdraw(amount);
    }

    function _fund(LockerFarm farm, uint256 amount) internal {
        vm.startPrank(OWNER);
        locker.approve(address(farm), amount);
        farm.fundRewards(amount);
        vm.stopPrank();
    }

    function _startEpoch(LockerFarm farm, uint256 amount) internal {
        vm.prank(OWNER);
        farm.startEpoch(amount);
    }
}
