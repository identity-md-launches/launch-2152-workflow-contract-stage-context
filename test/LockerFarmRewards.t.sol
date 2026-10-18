// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmTestBase} from "./FarmTestBase.sol";
import {LockerFarm} from "../src/LockerFarm.sol";

/// @notice LOCKER emissions: funding, epochs, rates, boosts, solvency and principal separation.
contract LockerFarmRewardsTest is FarmTestBase {
    function setUp() public override {
        super.setUp();
        _giveImd(ALICE, 1_000_000e18);
        _giveImd(BOB, 1_000_000e18);
        _giveLocker(ALICE, 1_000_000e18);
        _giveLocker(BOB, 1_000_000e18);
    }

    // ------------------------------------------------------------------ funding

    function test_fundingDoesNotChangeEmissions() public {
        _fund(imdFarm, 3_000e18);
        assertEq(imdFarm.rewardReserve(), 3_000e18);
        assertEq(imdFarm.rewardRate(), 0);
        assertEq(imdFarm.periodFinish(), 0);
        _startEpoch(imdFarm, 3_000e18);
        uint256 rate = imdFarm.rewardRate();
        _fund(imdFarm, 10_000e18);
        assertEq(imdFarm.rewardRate(), rate, "funding never raises the rate");
        assertEq(imdFarm.rewardReserve(), 10_000e18 + (3_000e18 - rate * EPOCH), "funds sit uncommitted");
    }

    function test_anyoneMayFund() public {
        vm.startPrank(ALICE);
        locker.approve(address(imdFarm), 5e18);
        imdFarm.fundRewards(5e18);
        vm.stopPrank();
        assertEq(imdFarm.rewardReserve(), 5e18);
    }

    function test_fundZeroReverts() public {
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        imdFarm.fundRewards(0);
    }

    // ------------------------------------------------------------------ epochs

    function test_startEpochCommitsReserveFor30Days() public {
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        uint256 rate = 3_000e18 / EPOCH;
        assertEq(imdFarm.rewardRate(), rate);
        assertEq(imdFarm.periodFinish(), block.timestamp + 30 days);
        assertEq(imdFarm.rewardReserve(), 3_000e18 - rate * EPOCH, "rounding dust returns to reserve");
        assertEq(imdFarm.getRewardForDuration(), rate * EPOCH);
        assertEq(imdFarm.epochTimeRemaining(), 30 days);
    }

    function test_startEpochBeyondReserveReverts() public {
        _fund(imdFarm, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, 1_001e18, 1_000e18));
        _startEpoch(imdFarm, 1_001e18);
    }

    function test_startEpochWithTinyAmountReverts() public {
        _fund(imdFarm, 1_000e18);
        vm.expectRevert(LockerFarm.RewardRateTooLow.selector);
        _startEpoch(imdFarm, 10);
    }

    function test_rewardsAccrueByStakeAndTime() public {
        _deposit(imdFarm, ALICE, 100e18);
        _deposit(imdFarm, BOB, 300e18);
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        uint256 rate = imdFarm.rewardRate();

        vm.warp(block.timestamp + 15 days);
        uint256 emitted = rate * 15 days;
        assertApproxEqAbs(imdFarm.earned(ALICE), emitted / 4, 1e6);
        assertApproxEqAbs(imdFarm.earned(BOB), emitted * 3 / 4, 1e6);

        vm.warp(block.timestamp + 30 days); // past the end: no further accrual
        uint256 total = rate * EPOCH;
        assertApproxEqAbs(imdFarm.earned(ALICE), total / 4, 1e6);
        assertApproxEqAbs(imdFarm.earned(BOB), total * 3 / 4, 1e6);
        assertLe(imdFarm.earned(ALICE) + imdFarm.earned(BOB), total, "never over-promises");

        uint256 before = locker.balanceOf(ALICE);
        vm.prank(ALICE);
        imdFarm.claimRewards();
        assertApproxEqAbs(locker.balanceOf(ALICE) - before, total / 4, 1e6);
        assertEq(imdFarm.earned(ALICE), 0);
    }

    function test_doubleClaimRewardsPaysNothingTwice() public {
        _deposit(imdFarm, ALICE, 100e18);
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        vm.warp(block.timestamp + 10 days);
        vm.startPrank(ALICE);
        imdFarm.claimRewards();
        uint256 after1 = locker.balanceOf(ALICE);
        imdFarm.claimRewards();
        vm.stopPrank();
        assertEq(locker.balanceOf(ALICE), after1);
    }

    function test_newEpochRollsLeftoverAndKeepsAccrued() public {
        _deposit(imdFarm, ALICE, 100e18);
        _fund(imdFarm, 6_000e18);
        _startEpoch(imdFarm, 3_000e18);
        vm.warp(block.timestamp + 10 days);
        uint256 accrued = imdFarm.earned(ALICE);
        uint256 leftover = imdFarm.remainingEpochRewards();

        _startEpoch(imdFarm, 3_000e18);
        assertApproxEqAbs(imdFarm.earned(ALICE), accrued, 1, "accrued rewards untouched");
        assertEq(imdFarm.periodFinish(), block.timestamp + 30 days);
        assertApproxEqAbs(imdFarm.rewardRate() * EPOCH, leftover + 3_000e18, EPOCH);
        assertLe(imdFarm.rewardReserve(), EPOCH, "only rounding dust left uncommitted");
    }

    function test_emissionsWithNoStakersReturnToReserve() public {
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        uint256 rate = imdFarm.rewardRate();
        uint256 reserve0 = imdFarm.rewardReserve();
        vm.warp(block.timestamp + 10 days);
        _deposit(imdFarm, ALICE, 1e18);
        assertEq(imdFarm.rewardReserve(), reserve0 + rate * 10 days, "unclaimable emissions recycled");
        vm.warp(block.timestamp + 20 days);
        assertApproxEqAbs(imdFarm.earned(ALICE), rate * 20 days, 1e6);
    }

    // ------------------------------------------------------------------ boosts and rates

    function test_boostEmissionsRaisesRateUntilSameEnd() public {
        _deposit(imdFarm, ALICE, 100e18);
        _fund(imdFarm, 6_000e18);
        _startEpoch(imdFarm, 3_000e18);
        uint256 finish = imdFarm.periodFinish();
        vm.warp(block.timestamp + 15 days);
        uint256 rateBefore = imdFarm.rewardRate();
        uint256 reserveBefore = imdFarm.rewardReserve();

        vm.prank(OWNER);
        imdFarm.boostEmissions(1_500e18);
        assertEq(imdFarm.periodFinish(), finish, "end time unchanged");
        assertApproxEqAbs(imdFarm.rewardRate(), rateBefore * 2, 1, "rate doubles for the remaining half");
        assertApproxEqAbs(imdFarm.rewardReserve(), reserveBefore - 1_500e18, 15 days);
    }

    function test_boostWithoutActiveEpochReverts() public {
        _fund(imdFarm, 3_000e18);
        vm.expectRevert(LockerFarm.NoActiveEpoch.selector);
        vm.prank(OWNER);
        imdFarm.boostEmissions(1e18);
    }

    function test_boostBeyondReserveReverts() public {
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        uint256 reserve = imdFarm.rewardReserve();
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, reserve + 1, reserve));
        vm.prank(OWNER);
        imdFarm.boostEmissions(reserve + 1);
    }

    function test_setRewardRateUpAndDownKeepsReserveExact() public {
        _deposit(imdFarm, ALICE, 100e18);
        _fund(imdFarm, 6_000e18);
        _startEpoch(imdFarm, 3_000e18);
        uint256 rate = imdFarm.rewardRate();
        uint256 reserve = imdFarm.rewardReserve();
        vm.warp(block.timestamp + 10 days);
        uint256 remaining = 20 days;

        vm.prank(OWNER);
        imdFarm.setRewardRate(rate * 2);
        assertEq(imdFarm.rewardReserve(), reserve - rate * remaining, "extra drawn from reserve");

        vm.prank(OWNER);
        imdFarm.setRewardRate(0);
        assertEq(imdFarm.rewardReserve(), reserve + rate * remaining, "lowering returns the difference");
        vm.warp(block.timestamp + 5 days);
        uint256 earnedPaused = imdFarm.earned(ALICE);
        vm.warp(block.timestamp + 5 days);
        assertEq(imdFarm.earned(ALICE), earnedPaused, "rate zero pauses accrual");
    }

    function test_setRewardRateBeyondReserveReverts() public {
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        uint256 remaining = 30 days;
        uint256 available = imdFarm.rewardReserve() + imdFarm.rewardRate() * remaining;
        uint256 tooHigh = available / remaining + 1;
        vm.expectRevert(
            abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, tooHigh * remaining, available)
        );
        vm.prank(OWNER);
        imdFarm.setRewardRate(tooHigh);
    }

    function test_setRewardRateWithoutEpochReverts() public {
        vm.expectRevert(LockerFarm.NoActiveEpoch.selector);
        vm.prank(OWNER);
        imdFarm.setRewardRate(1);
    }

    function test_returnUncommittedRewardsOnlyReserve() public {
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 1_000e18);
        uint256 reserve = imdFarm.rewardReserve();
        vm.prank(OWNER);
        imdFarm.returnUncommittedRewards(reserve);
        assertEq(locker.balanceOf(address(treasury)), reserve);
        assertEq(imdFarm.rewardReserve(), 0);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, 1, 0));
        vm.prank(OWNER);
        imdFarm.returnUncommittedRewards(1);
    }

    // ------------------------------------------------------------------ solvency and separation

    function test_principalCannotFundEmissionsOnLockerFarm() public {
        _deposit(lockerFarm, ALICE, 100_000e18);
        assertEq(locker.balanceOf(address(lockerFarm)), 100_000e18);
        assertEq(lockerFarm.rewardReserve(), 0);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, 1e18, 0));
        _startEpoch(lockerFarm, 1e18);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, 1, 0));
        vm.prank(OWNER);
        lockerFarm.returnUncommittedRewards(1);
    }

    function test_lockerFarmKeepsPrincipalFeesAndRewardsSeparate() public {
        _deposit(lockerFarm, ALICE, 1_000e18);
        _deposit(lockerFarm, BOB, 1_000e18);
        _fund(lockerFarm, 3_000e18);
        _startEpoch(lockerFarm, 3_000e18);
        vm.warp(block.timestamp + 30 days);

        _withdraw(lockerFarm, ALICE, 1_000e18); // Bob earns 90 LOCKER in fees, Treasury 10
        uint256 owed = lockerFarm.earned(ALICE) + lockerFarm.earned(BOB) + lockerFarm.pendingFees(BOB);
        assertGe(
            locker.balanceOf(address(lockerFarm)),
            lockerFarm.totalStaked() + owed + lockerFarm.rewardReserve(),
            "solvent"
        );

        vm.prank(BOB);
        lockerFarm.exit();
        vm.prank(ALICE);
        lockerFarm.claimRewards();
        assertEq(lockerFarm.totalStaked(), 0);
        assertApproxEqAbs(
            locker.balanceOf(address(lockerFarm)), lockerFarm.rewardReserve(), 10, "only reserve and dust remain"
        );
    }

    function test_accruedRewardsAreNotRecommitted() public {
        _deposit(imdFarm, ALICE, 100e18);
        _fund(imdFarm, 3_000e18);
        _startEpoch(imdFarm, 3_000e18);
        vm.warp(block.timestamp + 30 days);
        uint256 accrued = imdFarm.earned(ALICE);
        assertGt(accrued, 0);
        // The epoch is over; everything emitted belongs to Alice. The manager cannot start a new epoch from it.
        uint256 reserve = imdFarm.rewardReserve();
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, reserve + 1, reserve));
        _startEpoch(imdFarm, reserve + 1);
        vm.prank(ALICE);
        imdFarm.claimRewards();
        assertEq(locker.balanceOf(ALICE), 1_000_000e18 + accrued);
    }

    function testFuzz_epochNeverOverPromises(uint256 fundAmt, uint256 a, uint256 b, uint256 t) public {
        fundAmt = bound(fundAmt, EPOCH, 500_000e18);
        a = bound(a, 1, 1_000_000e18);
        b = bound(b, 1, 1_000_000e18);
        t = bound(t, 1, 60 days);
        _deposit(imdFarm, ALICE, a);
        _deposit(imdFarm, BOB, b);
        _fund(imdFarm, fundAmt);
        _startEpoch(imdFarm, fundAmt);
        vm.warp(block.timestamp + t);
        vm.prank(ALICE);
        imdFarm.claimRewards();
        vm.prank(BOB);
        imdFarm.claimRewards();
        uint256 paid = locker.balanceOf(ALICE) + locker.balanceOf(BOB) - 2_000_000e18;
        assertLe(paid, fundAmt - imdFarm.rewardReserve(), "paid at most what was committed");
        assertGe(locker.balanceOf(address(imdFarm)), imdFarm.rewardReserve() + imdFarm.remainingEpochRewards());
    }
}
