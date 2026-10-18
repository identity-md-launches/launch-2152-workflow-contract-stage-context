// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmTestBase} from "./FarmTestBase.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Role separation, renouncement and the emergency pause.
contract LockerFarmRolesTest is FarmTestBase {
    address internal constant MALLORY = address(0xBAD);
    address internal constant MULTISIG = address(0x5AFE);

    function setUp() public override {
        super.setUp();
        _giveImd(ALICE, 1_000e18);
        _fund(imdFarm, 3_000e18);
    }

    function test_initialRolesAreTheOwner() public view {
        assertEq(imdFarm.emissionsManager(), OWNER);
        assertEq(imdFarm.guardian(), OWNER);
        assertEq(imdFarm.treasury(), address(treasury));
        assertFalse(imdFarm.depositsPaused());
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(LockerFarm.ZeroAddress.selector);
        new LockerFarm(address(0), address(locker), address(treasury), OWNER);
        vm.expectRevert(LockerFarm.ZeroAddress.selector);
        new LockerFarm(address(imd), address(0), address(treasury), OWNER);
        vm.expectRevert(LockerFarm.ZeroAddress.selector);
        new LockerFarm(address(imd), address(locker), address(0), OWNER);
        vm.expectRevert(LockerFarm.ZeroAddress.selector);
        new LockerFarm(address(imd), address(locker), address(treasury), address(0));
    }

    // ------------------------------------------------------------------ emissions manager

    function test_onlyEmissionsManagerControlsEmissions() public {
        vm.startPrank(MALLORY);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.startEpoch(1e18);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.boostEmissions(1e18);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.setRewardRate(1);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.returnUncommittedRewards(1);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.setEmissionsManager(MALLORY);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.renounceEmissionsManager();
        vm.stopPrank();
    }

    function test_emissionsManagerCanBeTransferred() public {
        vm.prank(OWNER);
        imdFarm.setEmissionsManager(MULTISIG);
        assertEq(imdFarm.emissionsManager(), MULTISIG);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        vm.prank(OWNER);
        imdFarm.startEpoch(1e18);
        vm.prank(MULTISIG);
        imdFarm.startEpoch(1e18);
        assertGt(imdFarm.rewardRate(), 0);
    }

    function test_setEmissionsManagerToZeroReverts() public {
        vm.expectRevert(LockerFarm.ZeroAddress.selector);
        vm.prank(OWNER);
        imdFarm.setEmissionsManager(address(0));
    }

    function test_renouncedEmissionsManagerIsPermanent() public {
        _startEpoch(imdFarm, 1_000e18);
        vm.prank(OWNER);
        imdFarm.renounceEmissionsManager();
        assertEq(imdFarm.emissionsManager(), address(0));

        // Neither the old manager, a stranger, nor the zero address can act or reinstate the role.
        address[3] memory callers = [OWNER, MALLORY, address(0)];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.setEmissionsManager(OWNER);
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.startEpoch(1e18);
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.returnUncommittedRewards(1);
            vm.stopPrank();
        }

        // The running schedule, funding, staking and claiming keep working.
        _deposit(imdFarm, ALICE, 100e18);
        _fund(imdFarm, 10e18);
        vm.warp(block.timestamp + 5 days);
        assertGt(imdFarm.earned(ALICE), 0);
        vm.prank(ALICE);
        imdFarm.exit();
        // Guardian role is unaffected.
        assertEq(imdFarm.guardian(), OWNER);
    }

    // ------------------------------------------------------------------ guardian

    function test_onlyGuardianPauses() public {
        vm.startPrank(MALLORY);
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        imdFarm.pauseDeposits();
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        imdFarm.unpauseDeposits();
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        imdFarm.setGuardian(MALLORY);
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        imdFarm.renounceGuardian();
        vm.stopPrank();
    }

    function test_pauseBlocksDepositsButNeverWithdrawalsOrClaims() public {
        _deposit(imdFarm, ALICE, 500e18);
        vm.prank(OWNER);
        imdFarm.pauseDeposits();
        assertTrue(imdFarm.depositsPaused());

        vm.expectRevert(LockerFarm.DepositsArePaused.selector);
        _deposit(imdFarm, ALICE, 1e18);

        _withdraw(imdFarm, ALICE, 100e18);
        vm.startPrank(ALICE);
        imdFarm.claimFees();
        imdFarm.claimRewards();
        vm.stopPrank();
        assertEq(imdFarm.balanceOf(ALICE), 400e18);

        vm.prank(OWNER);
        imdFarm.unpauseDeposits();
        _deposit(imdFarm, ALICE, 1e18);
        assertEq(imdFarm.balanceOf(ALICE), 401e18);
    }

    function test_renounceGuardianUnpausesAndIsPermanent() public {
        vm.startPrank(OWNER);
        imdFarm.pauseDeposits();
        imdFarm.renounceGuardian();
        vm.stopPrank();
        assertEq(imdFarm.guardian(), address(0));
        assertFalse(imdFarm.depositsPaused(), "renouncing cannot leave deposits stuck");

        address[3] memory callers = [OWNER, MALLORY, address(0)];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(LockerFarm.NotGuardian.selector);
            imdFarm.pauseDeposits();
            vm.expectRevert(LockerFarm.NotGuardian.selector);
            imdFarm.setGuardian(OWNER);
            vm.stopPrank();
        }
        _deposit(imdFarm, ALICE, 1e18);
        // Emissions role is unaffected.
        assertEq(imdFarm.emissionsManager(), OWNER);
    }

    function test_guardianCanBeTransferred() public {
        vm.prank(OWNER);
        imdFarm.setGuardian(MULTISIG);
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        vm.prank(OWNER);
        imdFarm.pauseDeposits();
        vm.prank(MULTISIG);
        imdFarm.pauseDeposits();
        assertTrue(imdFarm.depositsPaused());
    }

    // ------------------------------------------------------------------ no hidden powers

    function test_treasuryHasNoPowerOverFarm() public {
        _deposit(imdFarm, ALICE, 500e18);
        vm.startPrank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientBalance.selector, 1, 0));
        imdFarm.withdraw(1);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.startEpoch(1);
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        imdFarm.pauseDeposits();
        vm.stopPrank();
        assertEq(imdFarm.balanceOf(ALICE), 500e18);
        assertEq(imd.balanceOf(address(imdFarm)), 500e18);
    }

    function test_recoverERC20OnlyForForeignTokens() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY");
        stray.mint(address(imdFarm), 42e18);
        imdFarm.recoverERC20(address(stray));
        assertEq(stray.balanceOf(address(treasury)), 42e18);

        vm.expectRevert(LockerFarm.ProtectedToken.selector);
        imdFarm.recoverERC20(address(imd));
        vm.expectRevert(LockerFarm.ProtectedToken.selector);
        imdFarm.recoverERC20(address(locker));
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        imdFarm.recoverERC20(address(stray));
    }
}
