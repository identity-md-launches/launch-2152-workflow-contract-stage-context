// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmTestBase} from "./FarmTestBase.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {LockerTreasury} from "../src/LockerTreasury.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Treasury custody, farm refills and the non-renounceable owner.
contract LockerTreasuryTest is FarmTestBase {
    address internal constant MALLORY = address(0xBAD);
    address internal constant TEAM = address(0x7EA3);

    function setUp() public override {
        super.setUp();
        // The requester moves 50% of the supply to the Treasury after launch.
        vm.prank(OWNER);
        locker.transfer(address(treasury), 500_000_000e18);
        _giveImd(ALICE, 1_000e18);
    }

    function test_ownerIsTheLaunchOwner() public view {
        assertEq(treasury.owner(), OWNER);
        assertEq(address(treasury.lockerToken()), address(locker));
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(LockerTreasury.ZeroAddress.selector);
        new LockerTreasury(OWNER, address(0));
    }

    function test_fundFarmRefillsReserveWithoutChangingEmissions() public {
        _fund(imdFarm, 1_000e18);
        _startEpoch(imdFarm, 1_000e18);
        uint256 rate = imdFarm.rewardRate();
        uint256 reserve = imdFarm.rewardReserve();

        vm.expectEmit(true, false, false, true);
        emit LockerTreasury.FarmFunded(address(imdFarm), 5_000e18);
        vm.prank(OWNER);
        treasury.fundFarm(address(imdFarm), 5_000e18);

        assertEq(imdFarm.rewardReserve(), reserve + 5_000e18);
        assertEq(imdFarm.rewardRate(), rate);
        assertEq(locker.balanceOf(address(treasury)), 500_000_000e18 - 5_000e18);
        assertEq(locker.allowance(address(treasury), address(imdFarm)), 0, "no dangling approval");
    }

    function test_fundFarmRejectsForeignRewardToken() public {
        LockerFarm other = new LockerFarm(address(locker), address(imd), address(treasury), OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(LockerTreasury.FarmRewardTokenMismatch.selector, address(other), address(imd))
        );
        vm.prank(OWNER);
        treasury.fundFarm(address(other), 1e18);
    }

    function test_fundFarmInputValidation() public {
        vm.startPrank(OWNER);
        vm.expectRevert(LockerTreasury.ZeroAddress.selector);
        treasury.fundFarm(address(0), 1e18);
        vm.expectRevert(LockerTreasury.ZeroAmount.selector);
        treasury.fundFarm(address(imdFarm), 0);
        vm.stopPrank();
    }

    function test_onlyOwnerMovesFunds() public {
        vm.startPrank(MALLORY);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MALLORY));
        treasury.fundFarm(address(imdFarm), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MALLORY));
        treasury.withdrawToken(address(locker), MALLORY, 1e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MALLORY));
        treasury.withdrawETH(MALLORY, 1);
        vm.stopPrank();
    }

    function test_withdrawTokenForManualBuybackAndSplit() public {
        // 1% fee share arrives in the staked token.
        _deposit(imdFarm, ALICE, 1_000e18);
        _withdraw(imdFarm, ALICE, 1_000e18);
        assertEq(imd.balanceOf(address(treasury)), 100e18);

        vm.startPrank(OWNER);
        treasury.withdrawToken(address(imd), TEAM, 20e18);
        treasury.withdrawToken(address(locker), OWNER, 1_000e18);
        vm.stopPrank();
        assertEq(imd.balanceOf(TEAM), 20e18);
        assertEq(imd.balanceOf(address(treasury)), 80e18);
        assertEq(locker.balanceOf(address(treasury)), 500_000_000e18 - 1_000e18);
    }

    function test_withdrawTokenValidation() public {
        vm.startPrank(OWNER);
        vm.expectRevert(LockerTreasury.ZeroAddress.selector);
        treasury.withdrawToken(address(locker), address(0), 1);
        vm.expectRevert(LockerTreasury.ZeroAmount.selector);
        treasury.withdrawToken(address(locker), OWNER, 0);
        vm.stopPrank();
    }

    function test_receiveAndWithdrawETH() public {
        vm.deal(ALICE, 2 ether);
        vm.prank(ALICE);
        (bool ok,) = address(treasury).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 2 ether);
        vm.prank(OWNER);
        treasury.withdrawETH(TEAM, 1.5 ether);
        assertEq(TEAM.balance, 1.5 ether);
        assertEq(address(treasury).balance, 0.5 ether);
    }

    function test_withdrawETHFailureReverts() public {
        vm.deal(address(treasury), 1 ether);
        // The farm has no receive function, so sending ETH to it fails.
        vm.expectRevert(LockerTreasury.ETHTransferFailed.selector);
        vm.prank(OWNER);
        treasury.withdrawETH(address(imdFarm), 1 ether);
    }

    function test_ownershipCannotBeRenounced() public {
        vm.expectRevert(LockerTreasury.OwnershipNotRenounceable.selector);
        vm.prank(OWNER);
        treasury.renounceOwnership();
        assertEq(treasury.owner(), OWNER);
    }

    function test_ownershipTransfersInTwoSteps() public {
        vm.prank(OWNER);
        treasury.transferOwnership(TEAM);
        assertEq(treasury.owner(), OWNER, "pending until accepted");
        assertEq(treasury.pendingOwner(), TEAM);
        vm.prank(TEAM);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), TEAM);
    }

    function test_treasuryCannotReachUserDepositsOrAccruedRewards() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        vm.warp(block.timestamp + 10 days);
        uint256 aliceRewards = imdFarm.earned(ALICE);
        assertGt(aliceRewards, 0);

        // Nothing the Treasury (or its owner through it) can call moves Alice's principal or rewards.
        vm.startPrank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientBalance.selector, 1, 0));
        imdFarm.withdraw(1);
        imdFarm.claimRewards(); // its own rewards: none
        imdFarm.claimFees();
        vm.stopPrank();
        // The Treasury holds no IMD yet, so even its owner cannot pull any out of it.
        vm.expectRevert();
        vm.prank(OWNER);
        treasury.withdrawToken(address(imd), OWNER, 1);
        assertEq(imdFarm.balanceOf(ALICE), 1_000e18);
        assertEq(imdFarm.earned(ALICE), aliceRewards);
        assertEq(imd.balanceOf(address(imdFarm)), 1_000e18);
    }
}
