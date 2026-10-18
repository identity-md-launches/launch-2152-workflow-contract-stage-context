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

    function test_emissionsManagerTransferIsTwoStep() public {
        vm.prank(OWNER);
        imdFarm.setEmissionsManager(MULTISIG);
        // Nothing changes until the new holder accepts; the mistyped-address case stays recoverable.
        assertEq(imdFarm.emissionsManager(), OWNER);
        assertEq(imdFarm.pendingEmissionsManager(), MULTISIG);
        vm.prank(OWNER);
        imdFarm.startEpoch(1e18);
        assertGt(imdFarm.rewardRate(), 0);

        vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
        vm.prank(MALLORY);
        imdFarm.acceptEmissionsManager();

        vm.expectEmit(true, true, false, true);
        emit LockerFarm.EmissionsManagerTransferred(OWNER, MULTISIG);
        vm.prank(MULTISIG);
        imdFarm.acceptEmissionsManager();
        assertEq(imdFarm.emissionsManager(), MULTISIG);
        assertEq(imdFarm.pendingEmissionsManager(), address(0));
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        vm.prank(OWNER);
        imdFarm.boostEmissions(1e18);
        vm.prank(MULTISIG);
        imdFarm.boostEmissions(1e18);
    }

    function test_emissionsManagerOfferCanBeCancelledOrReplaced() public {
        vm.startPrank(OWNER);
        imdFarm.setEmissionsManager(MALLORY); // mistyped
        imdFarm.setEmissionsManager(MULTISIG); // corrected
        vm.stopPrank();
        vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
        vm.prank(MALLORY);
        imdFarm.acceptEmissionsManager();
        vm.prank(OWNER);
        imdFarm.setEmissionsManager(address(0)); // cancelled
        assertEq(imdFarm.pendingEmissionsManager(), address(0));
        vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
        vm.prank(MULTISIG);
        imdFarm.acceptEmissionsManager();
        vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
        vm.prank(address(0));
        imdFarm.acceptEmissionsManager();
        assertEq(imdFarm.emissionsManager(), OWNER);
    }

    function test_renounceEmissionsManagerRequiresEmptyReserve() public {
        _startEpoch(imdFarm, 1_000e18);
        uint256 reserve = imdFarm.rewardReserve();
        assertGt(reserve, 0);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.ReserveNotEmpty.selector, reserve));
        vm.prank(OWNER);
        imdFarm.renounceEmissionsManager();
        assertEq(imdFarm.emissionsManager(), OWNER, "still in control");
    }

    function test_renouncedEmissionsManagerIsPermanent() public {
        _startEpoch(imdFarm, 1_000e18);
        vm.startPrank(OWNER);
        imdFarm.setEmissionsManager(MULTISIG); // a pending offer must die with the role
        imdFarm.returnUncommittedRewards(imdFarm.rewardReserve());
        imdFarm.renounceEmissionsManager();
        vm.stopPrank();
        assertEq(imdFarm.emissionsManager(), address(0));
        assertEq(imdFarm.pendingEmissionsManager(), address(0));

        // Neither the old manager, the former offeree, a stranger, nor the zero address can act or
        // reinstate the role.
        address[4] memory callers = [OWNER, MULTISIG, MALLORY, address(0)];
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.setEmissionsManager(OWNER);
            vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
            imdFarm.acceptEmissionsManager();
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.startEpoch(1e18);
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.boostEmissions(1e18);
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.setRewardRate(1);
            vm.stopPrank();
        }

        // Funding a farm nobody can emit from is refused, so LOCKER cannot be lost into it.
        vm.startPrank(OWNER);
        locker.approve(address(imdFarm), 10e18);
        vm.expectRevert(LockerFarm.EmissionsRenounced.selector);
        imdFarm.fundRewards(10e18);
        vm.stopPrank();

        // The running schedule, staking and claiming keep working.
        _deposit(imdFarm, ALICE, 100e18);
        vm.warp(block.timestamp + 5 days);
        assertGt(imdFarm.earned(ALICE), 0);
        vm.prank(ALICE);
        imdFarm.exit();
        // Guardian role is unaffected.
        assertEq(imdFarm.guardian(), OWNER);
    }

    function test_reserveReappearingAfterRenounceGoesToTreasury() public {
        _startEpoch(imdFarm, 1_000e18);
        vm.startPrank(OWNER);
        imdFarm.returnUncommittedRewards(imdFarm.rewardReserve());
        imdFarm.renounceEmissionsManager();
        vm.stopPrank();
        // Nobody is staked, so a span of the epoch recycles into the reserve.
        vm.warp(block.timestamp + 10 days);
        _deposit(imdFarm, ALICE, 1e18);
        uint256 recycled = imdFarm.rewardReserve();
        assertGt(recycled, 0);
        // With the role renounced anyone may send it to the immutable Treasury, nowhere else.
        uint256 before = locker.balanceOf(address(treasury));
        vm.prank(MALLORY);
        imdFarm.returnUncommittedRewards(recycled);
        assertEq(locker.balanceOf(address(treasury)) - before, recycled);
        assertEq(imdFarm.rewardReserve(), 0);
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

    function test_guardianTransferIsTwoStep() public {
        vm.prank(OWNER);
        imdFarm.setGuardian(MULTISIG);
        assertEq(imdFarm.guardian(), OWNER);
        assertEq(imdFarm.pendingGuardian(), MULTISIG);
        vm.expectRevert(LockerFarm.NotPendingGuardian.selector);
        vm.prank(MALLORY);
        imdFarm.acceptGuardian();
        vm.prank(MULTISIG);
        imdFarm.acceptGuardian();
        assertEq(imdFarm.guardian(), MULTISIG);
        assertEq(imdFarm.pendingGuardian(), address(0));
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        vm.prank(OWNER);
        imdFarm.pauseDeposits();
        vm.prank(MULTISIG);
        imdFarm.pauseDeposits();
        assertTrue(imdFarm.depositsPaused());
    }

    function test_renounceGuardianKillsPendingOffer() public {
        vm.startPrank(OWNER);
        imdFarm.setGuardian(MULTISIG);
        imdFarm.renounceGuardian();
        vm.stopPrank();
        assertEq(imdFarm.pendingGuardian(), address(0));
        vm.expectRevert(LockerFarm.NotPendingGuardian.selector);
        vm.prank(MULTISIG);
        imdFarm.acceptGuardian();
        assertEq(imdFarm.guardian(), address(0));
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

    function test_plainLockerTransferCanBeSyncedIntoReserve() public {
        _deposit(imdFarm, ALICE, 500e18);
        _startEpoch(imdFarm, 1_000e18);
        vm.warp(block.timestamp + 3 days);
        // LOCKER sent with a plain transfer instead of fundRewards: not in the reserve.
        vm.prank(OWNER);
        locker.transfer(address(imdFarm), 7e18);
        uint256 reserveBefore = imdFarm.rewardReserve();
        assertEq(imdFarm.untrackedBalance(address(locker)), 7e18);
        vm.expectRevert(
            abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, reserveBefore + 7e18, reserveBefore)
        );
        _startEpoch(imdFarm, reserveBefore + 7e18);

        vm.prank(MALLORY); // permissionless, only moves the excess into the reserve
        imdFarm.syncRewardReserve();
        assertEq(imdFarm.rewardReserve(), reserveBefore + 7e18);
        assertEq(imdFarm.untrackedBalance(address(locker)), 0);
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        imdFarm.syncRewardReserve();
        // The synced amount is real: it can be committed and the farm stays solvent for it.
        _startEpoch(imdFarm, reserveBefore + 7e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(ALICE);
        imdFarm.exit();
        assertGe(locker.balanceOf(address(imdFarm)), imdFarm.rewardReserve());
    }

    function test_syncNeverTouchesAccruedRewardsOrCommittedEmissions() public {
        _deposit(imdFarm, ALICE, 500e18);
        _startEpoch(imdFarm, 1_000e18);
        vm.warp(block.timestamp + 10 days);
        // Everything the farm holds is owed: reserve, accrued rewards and the rest of the epoch.
        assertEq(imdFarm.untrackedBalance(address(locker)), 0);
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        imdFarm.syncRewardReserve();
    }

    function test_excessStakingTokenGoesToTreasury() public {
        _deposit(imdFarm, ALICE, 500e18);
        imd.mint(address(imdFarm), 3e18); // plain transfer of the staking token
        assertEq(imdFarm.untrackedBalance(address(imd)), 3e18);
        vm.prank(MALLORY);
        imdFarm.recoverExcessStakingToken();
        assertEq(imd.balanceOf(address(treasury)), 3e18);
        assertEq(imd.balanceOf(address(imdFarm)), 500e18, "principal untouched");
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        imdFarm.recoverExcessStakingToken();
        // On the LOCKER farm the staking token is the reward token: only the reserve sync applies.
        vm.expectRevert(LockerFarm.ProtectedToken.selector);
        lockerFarm.recoverExcessStakingToken();
    }
}
