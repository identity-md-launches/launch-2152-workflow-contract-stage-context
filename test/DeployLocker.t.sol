// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLocker} from "../script/DeployLocker.s.sol";

/// @notice The deploy script wires every contract to the launch owner and never to the deployer.
contract DeployLockerTest is Test {
    address internal constant OWNER = address(0xDEA11b3A70b77134424d436f6eb455f1Abbd4449);

    function test_deployWiresOwnerEverywhere() public {
        DeployLocker script = new DeployLocker();
        DeployLocker.Deployment memory d = script.deploy(OWNER);

        assertEq(d.token.totalSupply(), 10 ** 27);
        assertEq(d.token.balanceOf(address(script)), 10 ** 27, "supply stays with the deployer (the factory)");

        assertEq(d.treasury.owner(), OWNER);
        assertEq(address(d.treasury.lockerToken()), address(d.token));

        assertEq(d.factory.owner(), OWNER);
        assertEq(d.factory.rewardToken(), address(d.token));
        assertEq(d.factory.treasury(), address(d.treasury));

        assertEq(address(d.lockerFarm.stakingToken()), address(d.token));
        assertEq(address(d.lockerFarm.rewardToken()), address(d.token));
        assertEq(d.lockerFarm.treasury(), address(d.treasury));
        assertEq(d.lockerFarm.emissionsManager(), OWNER);
        assertEq(d.lockerFarm.guardian(), OWNER);

        // Nothing is owned by the deployer.
        assertTrue(d.treasury.owner() != address(script) && d.factory.owner() != address(script));
        assertTrue(d.lockerFarm.emissionsManager() != address(script));
    }

    function test_deployRejectsZeroOwner() public {
        DeployLocker script = new DeployLocker();
        vm.expectRevert();
        script.deploy(address(0));
    }
}
