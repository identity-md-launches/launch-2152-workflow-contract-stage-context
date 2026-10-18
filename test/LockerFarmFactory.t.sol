// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmTestBase} from "./FarmTestBase.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {LockerFarmFactory} from "../src/LockerFarmFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Farm creation, registration and the renounceable farm-creation role.
contract LockerFarmFactoryTest is FarmTestBase {
    address internal constant MALLORY = address(0xBAD);
    MockERC20 internal simd;

    function setUp() public override {
        super.setUp();
        simd = new MockERC20("Staked IMD", "sIMD");
    }

    function test_configuration() public view {
        assertEq(factory.owner(), OWNER);
        assertEq(factory.rewardToken(), address(locker));
        assertEq(factory.treasury(), address(treasury));
        assertEq(factory.farmCount(), 1);
        assertEq(factory.farmAt(0), address(imdFarm));
        assertTrue(factory.isFarm(address(imdFarm)));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(LockerFarmFactory.ZeroAddress.selector);
        new LockerFarmFactory(OWNER, address(0), address(treasury));
        vm.expectRevert(LockerFarmFactory.ZeroAddress.selector);
        new LockerFarmFactory(OWNER, address(locker), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LockerFarmFactory(address(0), address(locker), address(treasury));
    }

    function test_createFarmWiresTheNewFarmAndLeavesOthersAlone() public {
        _giveImd(ALICE, 100e18);
        _deposit(imdFarm, ALICE, 100e18);
        uint256 imdStakedBefore = imdFarm.totalStaked();

        vm.prank(OWNER);
        address farmAddr = factory.createFarm(address(simd), OWNER);
        LockerFarm simdFarm = LockerFarm(farmAddr);

        assertEq(address(simdFarm.stakingToken()), address(simd));
        assertEq(address(simdFarm.rewardToken()), address(locker));
        assertEq(simdFarm.treasury(), address(treasury));
        assertEq(simdFarm.emissionsManager(), OWNER);
        assertEq(simdFarm.guardian(), OWNER);
        assertEq(simdFarm.totalStaked(), 0);
        assertEq(simdFarm.rewardReserve(), 0);

        assertEq(factory.farmCount(), 2);
        assertEq(factory.farmAt(1), farmAddr);
        assertTrue(factory.isFarm(farmAddr));
        assertEq(factory.farmsByToken(address(simd)).length, 1);
        assertEq(factory.farmsByToken(address(simd))[0], farmAddr);
        assertEq(factory.allFarms().length, 2);

        // The existing IMD farm is untouched.
        assertEq(imdFarm.totalStaked(), imdStakedBefore);
        assertEq(imdFarm.balanceOf(ALICE), 100e18);
    }

    function test_createFarmWithCustomAdmin() public {
        address multisig = address(0x5AFE);
        vm.prank(OWNER);
        LockerFarm farm = LockerFarm(factory.createFarm(address(simd), multisig));
        assertEq(farm.emissionsManager(), multisig);
        assertEq(farm.guardian(), multisig);
    }

    function test_createFarmValidation() public {
        vm.startPrank(OWNER);
        vm.expectRevert(LockerFarmFactory.ZeroAddress.selector);
        factory.createFarm(address(0), OWNER);
        vm.expectRevert(LockerFarmFactory.ZeroAddress.selector);
        factory.createFarm(address(simd), address(0));
        vm.stopPrank();
    }

    function test_onlyOwnerCreatesOrRegisters() public {
        vm.startPrank(MALLORY);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MALLORY));
        factory.createFarm(address(simd), MALLORY);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MALLORY));
        factory.registerFarm(address(lockerFarm));
        vm.stopPrank();
    }

    function test_registerLaunchDeployedFarm() public {
        vm.prank(OWNER);
        factory.registerFarm(address(lockerFarm));
        assertTrue(factory.isFarm(address(lockerFarm)));
        assertEq(factory.farmsByToken(address(locker))[0], address(lockerFarm));

        vm.expectRevert(abi.encodeWithSelector(LockerFarmFactory.AlreadyRegistered.selector, address(lockerFarm)));
        vm.prank(OWNER);
        factory.registerFarm(address(lockerFarm));
    }

    function test_registerRejectsMismatchedFarm() public {
        LockerFarm wrongReward = new LockerFarm(address(simd), address(imd), address(treasury), OWNER);
        LockerFarm wrongTreasury = new LockerFarm(address(simd), address(locker), address(0xDEAD1), OWNER);
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(LockerFarmFactory.FarmMismatch.selector, address(wrongReward)));
        factory.registerFarm(address(wrongReward));
        vm.expectRevert(abi.encodeWithSelector(LockerFarmFactory.FarmMismatch.selector, address(wrongTreasury)));
        factory.registerFarm(address(wrongTreasury));
        vm.expectRevert(LockerFarmFactory.ZeroAddress.selector);
        factory.registerFarm(address(0));
        vm.stopPrank();
    }

    function test_renouncedFarmCreationIsPermanent() public {
        vm.prank(OWNER);
        factory.renounceOwnership();
        assertEq(factory.owner(), address(0));

        address[3] memory callers = [OWNER, MALLORY, address(0)];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            factory.createFarm(address(simd), OWNER);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            factory.transferOwnership(OWNER);
            vm.stopPrank();
        }
        // Existing farms and the Treasury keep working.
        assertEq(imdFarm.emissionsManager(), OWNER);
        assertEq(treasury.owner(), OWNER);
    }

    function test_ownershipTransfersInTwoSteps() public {
        address multisig = address(0x5AFE);
        vm.prank(OWNER);
        factory.transferOwnership(multisig);
        assertEq(factory.owner(), OWNER);
        vm.prank(multisig);
        factory.acceptOwnership();
        assertEq(factory.owner(), multisig);
    }
}
