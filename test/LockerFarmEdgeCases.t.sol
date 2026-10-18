// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmTestBase} from "./FarmTestBase.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {LockerFarmFactory} from "../src/LockerFarmFactory.sol";
import {LockerTreasury} from "../src/LockerTreasury.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Adversarial edges the main suites do not pin: epoch boundaries, zero and one-second windows,
///      exact reward totals, fee-on-transfer tokens, stale role holders, renounced owners spoofed as
///      `address(0)`, and fuzzed fee splits with several depositors.
contract LockerFarmEdgeCasesTest is FarmTestBase {
    address internal constant DAVE = address(0xDA4E);

    // ---------------------------------------------------------------------------------------
    // Epoch boundaries and exact reward totals
    // ---------------------------------------------------------------------------------------

    function test_singleStakerEarnsTheWholeEpochAndNothingAfter() public {
        _giveImd(ALICE, 100 ether);
        _deposit(imdFarm, ALICE, 100 ether);
        _fund(imdFarm, 30_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        uint256 committed = imdFarm.getRewardForDuration();

        vm.warp(block.timestamp + EPOCH);
        uint256 atEnd = imdFarm.earned(ALICE);
        assertApproxEqAbs(atEnd, committed, 1e6, "staker should earn the whole committed epoch");
        assertLe(atEnd, committed, "earned more than committed");

        vm.warp(block.timestamp + 365 days);
        assertEq(imdFarm.earned(ALICE), atEnd, "accrual continued after periodFinish");
        assertEq(imdFarm.epochTimeRemaining(), 0);
        assertEq(imdFarm.remainingEpochRewards(), 0);

        vm.prank(ALICE);
        imdFarm.claimRewards();
        assertEq(locker.balanceOf(ALICE), atEnd);
    }

    function test_twoStakersSplitByStakeAndTime() public {
        _giveImd(ALICE, 300 ether);
        _giveImd(BOB, 100 ether);
        _fund(imdFarm, 300_000 ether);
        _deposit(imdFarm, ALICE, 300 ether);
        _startEpoch(imdFarm, 300_000 ether);
        uint256 rate = imdFarm.rewardRate();

        vm.warp(block.timestamp + 10 days);
        _deposit(imdFarm, BOB, 100 ether);
        vm.warp(block.timestamp + 20 days);

        // Alice: 10 days alone + 20 days at 3/4. Bob: 20 days at 1/4.
        uint256 aliceExpected = rate * 10 days + rate * 20 days * 3 / 4;
        uint256 bobExpected = rate * 20 days / 4;
        assertApproxEqAbs(imdFarm.earned(ALICE), aliceExpected, 1e6);
        assertApproxEqAbs(imdFarm.earned(BOB), bobExpected, 1e6);
        assertLe(imdFarm.earned(ALICE) + imdFarm.earned(BOB), rate * EPOCH);
    }

    function test_startEpochExactlyAtPeriodFinishRollsNothing() public {
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        _fund(imdFarm, 60_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        uint256 reserveAfterFirst = imdFarm.rewardReserve();

        vm.warp(imdFarm.periodFinish());
        assertEq(imdFarm.remainingEpochRewards(), 0);
        _startEpoch(imdFarm, 30_000 ether);
        assertEq(imdFarm.rewardRate(), uint256(30_000 ether) / EPOCH, "rate must not include a stale leftover");
        assertEq(imdFarm.periodFinish(), block.timestamp + EPOCH);
        // Only the rounding dust of the new commitment returns to the reserve.
        assertEq(imdFarm.rewardReserve(), reserveAfterFirst - 30_000 ether + (30_000 ether % EPOCH));
    }

    function test_startEpochWithZeroAmountRestartsFromLeftover() public {
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        _fund(imdFarm, 30_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        vm.warp(block.timestamp + 15 days);
        uint256 leftover = imdFarm.remainingEpochRewards();

        _startEpoch(imdFarm, 0);
        assertEq(imdFarm.rewardRate(), leftover / EPOCH, "leftover is respread over a fresh 30 days");
        assertEq(imdFarm.periodFinish(), block.timestamp + EPOCH);
    }

    function test_startEpochWithZeroAndNoEpochReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(LockerFarm.RewardRateTooLow.selector);
        imdFarm.startEpoch(0);
    }

    function test_boostInLastSecondCommitsWholeAmountToOneSecond() public {
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        _fund(imdFarm, 40_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        vm.warp(imdFarm.periodFinish() - 1);
        uint256 rate = imdFarm.rewardRate();
        uint256 before = imdFarm.earned(ALICE);

        vm.prank(OWNER);
        imdFarm.boostEmissions(1_000 ether);
        assertEq(imdFarm.rewardRate(), rate + 1_000 ether);

        vm.warp(block.timestamp + 1);
        assertApproxEqAbs(imdFarm.earned(ALICE) - before, rate + 1_000 ether, 1e6);
        vm.prank(OWNER);
        vm.expectRevert(LockerFarm.NoActiveEpoch.selector);
        imdFarm.boostEmissions(1 ether);
    }

    function test_boostZeroReverts() public {
        _fund(imdFarm, 30_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        vm.prank(OWNER);
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        imdFarm.boostEmissions(0);
    }

    function test_setRewardRateZeroStopsAccrualAndRestoresReserve() public {
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        _fund(imdFarm, 30_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        uint256 reserve0 = imdFarm.rewardReserve();
        vm.warp(block.timestamp + 10 days);
        uint256 leftover = imdFarm.remainingEpochRewards();

        vm.prank(OWNER);
        imdFarm.setRewardRate(0);
        assertEq(imdFarm.rewardReserve(), reserve0 + leftover, "unemitted rewards go back to the reserve");
        uint256 frozen = imdFarm.earned(ALICE);
        vm.warp(block.timestamp + 5 days);
        assertEq(imdFarm.earned(ALICE), frozen, "zero rate still accrued");

        // The reserve can then be returned to the Treasury, but never what Alice already earned.
        uint256 reserve = imdFarm.rewardReserve();
        vm.prank(OWNER);
        imdFarm.returnUncommittedRewards(reserve);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, 1, 0));
        imdFarm.returnUncommittedRewards(1);
        vm.prank(ALICE);
        imdFarm.claimRewards();
        assertEq(locker.balanceOf(ALICE), frozen);
    }

    function test_emissionsManagerCannotPullBackAccruedRewards() public {
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        _fund(imdFarm, 30_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        vm.warp(block.timestamp + 20 days);
        uint256 accrued = imdFarm.earned(ALICE);

        vm.startPrank(OWNER);
        imdFarm.setRewardRate(0);
        imdFarm.returnUncommittedRewards(imdFarm.rewardReserve());
        vm.stopPrank();

        assertGe(locker.balanceOf(address(imdFarm)), accrued, "accrued rewards left the farm");
        vm.prank(ALICE);
        imdFarm.claimRewards();
        assertEq(locker.balanceOf(ALICE), accrued);
        assertEq(locker.balanceOf(address(imdFarm)), 0, "nothing should remain once all is paid out");
    }

    function test_rewardsDuringEmptyFarmAreNotLostAcrossEpochEnd() public {
        _fund(imdFarm, 30_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        uint256 committed = imdFarm.getRewardForDuration();
        uint256 reserve0 = imdFarm.rewardReserve();
        // Nobody stakes for the whole epoch and beyond.
        vm.warp(block.timestamp + EPOCH + 10 days);
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        assertEq(imdFarm.rewardReserve(), reserve0 + committed, "emissions with no staker must return to reserve");
        vm.warp(block.timestamp + 1 days);
        assertEq(imdFarm.earned(ALICE), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Withdrawal fee edges
    // ---------------------------------------------------------------------------------------

    function test_withdrawerEarnsNothingFromOwnFeeEvenWhenTheOnlyOtherStakeIsOneWei() public {
        _giveImd(ALICE, 100 ether);
        _giveImd(BOB, 1);
        _deposit(imdFarm, ALICE, 100 ether);
        _deposit(imdFarm, BOB, 1);
        _matureStakes();

        _withdraw(imdFarm, ALICE, 50 ether);
        assertEq(imdFarm.pendingFees(ALICE), 0, "self fee");
        assertEq(imdFarm.pendingFees(BOB), 4.5 ether, "the single wei of other stake receives all 9%");

        // Bob claims his huge per-share fee; Alice's remaining stake is still worth only her principal.
        vm.prank(BOB);
        imdFarm.claimFees();
        assertEq(imd.balanceOf(BOB), 4.5 ether);
        vm.prank(ALICE);
        imdFarm.exit();
        assertEq(imd.balanceOf(ALICE), 45 ether + 45 ether);
        assertEq(imdFarm.pendingFees(ALICE), 0);
        assertEq(imdFarm.pendingFees(BOB), 4.5 ether, "Bob gets 9% of Alice's second withdrawal too");
    }

    function test_repeatedPartialWithdrawalsNeverPayTheWithdrawer() public {
        _giveImd(ALICE, 1_000 ether);
        _giveImd(BOB, 1_000 ether);
        _deposit(imdFarm, ALICE, 1_000 ether);
        _deposit(imdFarm, BOB, 1_000 ether);
        _matureStakes();

        for (uint256 i; i < 10; ++i) {
            _withdraw(imdFarm, ALICE, 50 ether);
            assertEq(imdFarm.pendingFees(ALICE), 0, "withdrawer accrued from own fee");
        }
        // Bob was the only other depositor for all ten withdrawals.
        assertApproxEqAbs(imdFarm.pendingFees(BOB), 45 ether, 10);
        assertLe(imdFarm.pendingFees(BOB), 45 ether);
        assertEq(imd.balanceOf(address(treasury)), 5 ether);
    }

    function test_fullWithdrawalThenRedepositDoesNotEarnOldFees() public {
        _giveImd(ALICE, 100 ether);
        _giveImd(BOB, 100 ether);
        _deposit(imdFarm, ALICE, 100 ether);
        _deposit(imdFarm, BOB, 100 ether);
        _matureStakes();
        _withdraw(imdFarm, BOB, 100 ether); // Alice earns 9
        _withdraw(imdFarm, ALICE, 100 ether); // nobody else: all to Treasury

        _giveImd(BOB, 10 ether);
        _deposit(imdFarm, BOB, 10 ether);
        assertEq(imdFarm.pendingFees(BOB), 0, "re-depositor inherited old fee growth");
        assertEq(imdFarm.pendingFees(ALICE), 9 ether, "Alice's fees survive full withdrawal");
        // Once Bob's new stake matures it still holds nothing of the old fee growth.
        _matureStakes();
        assertEq(imdFarm.pendingFees(BOB), 0, "matured re-deposit inherited old fee growth");
        assertEq(imdFarm.eligibleStakeOf(BOB), 10 ether);
    }

    function test_feeOnLargeWithdrawalIsExact() public {
        uint256 big = 300_000_000 ether;
        _giveLocker(ALICE, big);
        _giveLocker(BOB, 1 ether);
        _deposit(lockerFarm, ALICE, big);
        _deposit(lockerFarm, BOB, 1 ether);
        _matureStakes();
        _withdraw(lockerFarm, ALICE, big);
        assertEq(locker.balanceOf(ALICE), big * 9 / 10);
        assertEq(locker.balanceOf(address(treasury)), big / 100);
        assertEq(lockerFarm.pendingFees(BOB), big * 9 / 100);
        vm.prank(BOB);
        lockerFarm.exit();
        // Bob paid his own 10% fee to the Treasury (no other depositor left).
        assertEq(locker.balanceOf(BOB), big * 9 / 100 + 0.9 ether);
        assertEq(locker.balanceOf(address(lockerFarm)), 0);
    }

    function test_withdrawByNonDepositorRevertsWithBalance() public {
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientBalance.selector, 1, 0));
        imdFarm.withdraw(1);
    }

    function test_exitAndClaimsWithNothingAreHarmlessNoOps() public {
        vm.startPrank(CAROL);
        imdFarm.exit();
        imdFarm.claimFees();
        imdFarm.claimRewards();
        vm.stopPrank();
        assertEq(imd.balanceOf(CAROL), 0);
        assertEq(locker.balanceOf(CAROL), 0);
    }

    function test_farmsAreIsolated() public {
        _giveImd(ALICE, 100 ether);
        _giveLocker(BOB, 100 ether);
        _giveLocker(CAROL, 100 ether);
        _deposit(imdFarm, ALICE, 100 ether);
        _deposit(lockerFarm, BOB, 100 ether);
        _deposit(lockerFarm, CAROL, 100 ether);
        _matureStakes();
        _fund(lockerFarm, 30_000 ether);
        _startEpoch(lockerFarm, 30_000 ether);

        vm.warp(block.timestamp + 1 days);
        _withdraw(lockerFarm, BOB, 100 ether);

        assertEq(imdFarm.pendingFees(ALICE), 0, "fee leaked across farms");
        assertEq(imdFarm.earned(ALICE), 0, "emissions leaked across farms");
        assertEq(imdFarm.rewardReserve(), 0);
        assertEq(imdFarm.totalStaked(), 100 ether);
        assertEq(lockerFarm.pendingFees(CAROL), 9 ether);
    }

    function testFuzz_withdrawSplitAmongManyDepositors(uint256 a, uint256 b, uint256 c, uint256 d, uint256 w) public {
        a = bound(a, 1, 1e30);
        b = bound(b, 0, 1e30);
        c = bound(c, 0, 1e30);
        d = bound(d, 0, 1e30);
        w = bound(w, 1, a);
        _giveImd(ALICE, a);
        _deposit(imdFarm, ALICE, a);
        if (b > 0) _seed(BOB, b);
        if (c > 0) _seed(CAROL, c);
        if (d > 0) _seed(DAVE, d);
        uint256 others = b + c + d;
        _matureStakes();

        _withdraw(imdFarm, ALICE, w);

        // The 10% rounds up to the wei; the 9% share rounds down.
        uint256 fee = (w + 9) / 10;
        uint256 redistributed = others > 0 ? w * 9 / 100 : 0;
        assertEq(imd.balanceOf(ALICE), w - fee, "payout");
        assertEq(imd.balanceOf(address(treasury)), fee - redistributed, "treasury share");
        assertEq(imdFarm.pendingFees(ALICE), 0, "self fee");

        uint256 sumPending = imdFarm.pendingFees(BOB) + imdFarm.pendingFees(CAROL) + imdFarm.pendingFees(DAVE);
        assertLe(sumPending, redistributed, "other depositors were promised more than redistributed");
        // Rounding loses at most one wei per depositor plus the per-share truncation.
        if (others > 0) assertApproxEqAbs(sumPending, redistributed, 3 + others / 1e18 + 1);
        _checkShare(BOB, b, others, redistributed);
        _checkShare(CAROL, c, others, redistributed);
        _checkShare(DAVE, d, others, redistributed);

        // Every promise is payable.
        assertGe(imd.balanceOf(address(imdFarm)), imdFarm.totalStaked() + sumPending);
    }

    /// @dev Fee is ceil(10%) of the amount: never less than 10%, at most 1 wei over, never zero.
    function testFuzz_feeIsTenPercentRoundedUp(uint256 w) public {
        w = bound(w, 1, 1e30);
        _giveImd(ALICE, w);
        _deposit(imdFarm, ALICE, w);
        _withdraw(imdFarm, ALICE, w);
        uint256 fee = imd.balanceOf(address(treasury));
        assertGe(fee * 10, w, "fee below 10%");
        assertLt((fee - 1) * 10, w, "fee more than 1 wei above 10%");
        assertEq(imd.balanceOf(ALICE) + fee, w);
    }

    // ---------------------------------------------------------------------------------------
    // Fee-on-transfer tokens
    // ---------------------------------------------------------------------------------------

    function test_feeOnTransferStakingTokenCreditsReceivedAmount() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        vm.prank(OWNER);
        LockerFarm farm = LockerFarm(factory.createFarm(address(taxed), OWNER));
        taxed.mint(ALICE, 100 ether);
        taxed.mint(BOB, 100 ether);
        vm.prank(ALICE);
        taxed.approve(address(farm), type(uint256).max);
        vm.prank(BOB);
        taxed.approve(address(farm), type(uint256).max);

        vm.prank(ALICE);
        farm.deposit(100 ether);
        vm.prank(BOB);
        farm.deposit(100 ether);
        assertEq(farm.balanceOf(ALICE), 99 ether, "credited more than received");
        assertEq(farm.totalStaked(), 198 ether);

        vm.prank(ALICE);
        farm.exit();
        vm.prank(BOB);
        farm.exit();
        // The farm never pays out more than it holds.
        assertEq(farm.totalStaked(), 0);
        assertEq(farm.pendingFees(BOB), 0);
        assertGe(taxed.balanceOf(address(farm)), 0);
    }

    function test_feeOnTransferRewardTokenCreditsReceivedReserve() public {
        FeeOnTransferToken taxedReward = new FeeOnTransferToken();
        LockerTreasury t = new LockerTreasury(OWNER, address(taxedReward));
        LockerFarm farm = new LockerFarm(address(imd), address(taxedReward), address(t), OWNER);
        taxedReward.mint(OWNER, 1_000 ether);
        vm.startPrank(OWNER);
        taxedReward.approve(address(farm), 1_000 ether);
        farm.fundRewards(1_000 ether);
        vm.stopPrank();
        assertEq(farm.rewardReserve(), 990 ether);
        assertEq(taxedReward.balanceOf(address(farm)), 990 ether);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientRewardReserve.selector, 1_000 ether, 990 ether));
        farm.startEpoch(1_000 ether);
    }

    // ---------------------------------------------------------------------------------------
    // Roles: stale holders and spoofed zero address
    // ---------------------------------------------------------------------------------------

    function test_previousEmissionsManagerLosesEveryPower() public {
        _fund(imdFarm, 30_000 ether);
        vm.prank(OWNER);
        imdFarm.setEmissionsManager(CAROL);
        // An offer alone moves nothing: the owner keeps the role until Carol accepts.
        assertEq(imdFarm.emissionsManager(), OWNER);
        vm.prank(BOB);
        vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
        imdFarm.acceptEmissionsManager();
        vm.prank(CAROL);
        imdFarm.acceptEmissionsManager();
        assertEq(imdFarm.emissionsManager(), CAROL);
        assertEq(imdFarm.pendingEmissionsManager(), address(0));
        vm.prank(CAROL);
        vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
        imdFarm.acceptEmissionsManager();

        vm.startPrank(OWNER);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.startEpoch(30_000 ether);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.returnUncommittedRewards(1);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.setEmissionsManager(OWNER);
        vm.stopPrank();

        // The guardian role is separate and stays with the owner.
        vm.prank(OWNER);
        imdFarm.pauseDeposits();
        assertTrue(imdFarm.depositsPaused());
    }

    function test_renouncedRolesCannotBeUsedByZeroAddress() public {
        vm.startPrank(OWNER);
        imdFarm.renounceEmissionsManager();
        imdFarm.renounceGuardian();
        vm.stopPrank();

        vm.startPrank(address(0));
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.setEmissionsManager(OWNER);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.startEpoch(0);
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        imdFarm.setGuardian(OWNER);
        vm.expectRevert(LockerFarm.NotGuardian.selector);
        imdFarm.pauseDeposits();
        vm.stopPrank();

        // Renouncing one farm's roles leaves every other farm's roles alone.
        assertEq(lockerFarm.emissionsManager(), OWNER);
        assertEq(lockerFarm.guardian(), OWNER);
    }

    function test_renouncingOneRoleKeepsTheOther() public {
        vm.prank(OWNER);
        imdFarm.renounceGuardian();
        assertEq(imdFarm.emissionsManager(), OWNER);
        _fund(imdFarm, 30_000 ether);
        _startEpoch(imdFarm, 30_000 ether);
        assertGt(imdFarm.rewardRate(), 0);
    }

    function test_factoryRenounceClearsPendingOwnerAndBlocksZeroAddress() public {
        vm.startPrank(OWNER);
        factory.transferOwnership(CAROL);
        factory.renounceOwnership();
        vm.stopPrank();
        assertEq(factory.pendingOwner(), address(0));

        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, CAROL));
        factory.acceptOwnership();

        vm.startPrank(address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0)));
        factory.createFarm(address(imd), OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0)));
        factory.registerFarm(address(lockerFarm));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0)));
        factory.transferOwnership(address(0));
        vm.stopPrank();

        // Existing farms keep working after farm creation is renounced.
        _giveImd(ALICE, 1 ether);
        _deposit(imdFarm, ALICE, 1 ether);
        assertEq(imdFarm.totalStaked(), 1 ether);
    }

    function test_factoryRejectsDuplicateRegistration() public {
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(LockerFarmFactory.AlreadyRegistered.selector, address(imdFarm)));
        factory.registerFarm(address(imdFarm));
        factory.registerFarm(address(lockerFarm));
        vm.expectRevert(abi.encodeWithSelector(LockerFarmFactory.AlreadyRegistered.selector, address(lockerFarm)));
        factory.registerFarm(address(lockerFarm));
        vm.stopPrank();
        assertEq(factory.farmCount(), 2);
        assertEq(factory.farmsByToken(address(locker)).length, 1);
    }

    function test_factoryRegisterRejectsNonFarm() public {
        vm.prank(OWNER);
        vm.expectRevert();
        factory.registerFarm(address(imd));
    }

    function test_factoryFarmAtOutOfRangeReverts() public {
        vm.expectRevert();
        factory.farmAt(1);
    }

    function test_secondFarmForSameTokenIsIndependent() public {
        vm.prank(OWNER);
        LockerFarm second = LockerFarm(factory.createFarm(address(imd), OWNER));
        assertEq(factory.farmsByToken(address(imd)).length, 2);
        _giveImd(ALICE, 10 ether);
        _deposit(imdFarm, ALICE, 10 ether);
        assertEq(second.totalStaked(), 0);
        assertEq(imd.allowance(ALICE, address(second)), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Treasury edges
    // ---------------------------------------------------------------------------------------

    function test_treasuryFundFarmBeyondBalanceReverts() public {
        vm.prank(OWNER);
        vm.expectRevert();
        treasury.fundFarm(address(imdFarm), 1 ether);
        assertEq(imdFarm.rewardReserve(), 0);
    }

    function test_treasuryFundFarmToNonFarmReverts() public {
        vm.prank(OWNER);
        locker.transfer(address(treasury), 10 ether);
        vm.startPrank(OWNER);
        vm.expectRevert();
        treasury.fundFarm(CAROL, 1 ether);
        vm.expectRevert();
        treasury.fundFarm(address(imd), 1 ether);
        vm.stopPrank();
        assertEq(locker.balanceOf(address(treasury)), 10 ether);
        assertEq(locker.allowance(address(treasury), address(imd)), 0);
    }

    function test_treasuryLeavesNoAllowanceAfterFunding() public {
        vm.prank(OWNER);
        locker.transfer(address(treasury), 10 ether);
        vm.prank(OWNER);
        treasury.fundFarm(address(lockerFarm), 4 ether);
        assertEq(locker.allowance(address(treasury), address(lockerFarm)), 0);
        assertEq(lockerFarm.rewardReserve(), 4 ether);
        assertEq(lockerFarm.totalStaked(), 0, "Treasury funding must not count as principal");
    }

    function test_treasuryRenounceByStrangerReverts() public {
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, CAROL));
        treasury.renounceOwnership();
        assertEq(treasury.owner(), OWNER);
    }

    // ---------------------------------------------------------------------------------------
    // Fee-eligibility delay edges
    // ---------------------------------------------------------------------------------------

    function test_eligibilityBoundaryIsExactToTheSecond() public {
        _giveImd(ALICE, 1_000 ether);
        _deposit(imdFarm, ALICE, 1_000 ether);
        _matureStakes();

        // Bob deposits in the last second of a bucket: eligible one day and one second later.
        uint256 bucket = block.timestamp / 1 days;
        vm.warp((bucket + 1) * 1 days - 1);
        _giveImd(BOB, 100 ether);
        _deposit(imdFarm, BOB, 100 ether);
        uint256 maturity = (bucket + 2) * 1 days;
        assertEq(imdFarm.feeEligibilityStart(), maturity);

        vm.warp(maturity - 1);
        assertEq(imdFarm.eligibleStakeOf(BOB), 0);
        assertEq(imdFarm.pendingStakeOf(BOB), 100 ether);
        _withdraw(imdFarm, ALICE, 100 ether);
        assertEq(imdFarm.pendingFees(BOB), 0, "pending stake shared a fee one second early");
        assertEq(imd.balanceOf(address(treasury)), 10 ether, "no eligible other: all 10% to Treasury");

        vm.warp(maturity);
        assertEq(imdFarm.eligibleStakeOf(BOB), 100 ether);
        assertEq(imdFarm.pendingFees(BOB), 0, "maturing stake was credited the earlier fee");
        _withdraw(imdFarm, ALICE, 100 ether);
        assertEq(imdFarm.pendingFees(BOB), 9 ether, "matured stake missed the fee");
        assertEq(imd.balanceOf(address(treasury)), 11 ether);
    }

    function test_topUpAfterMaturityKeepsEligibleStakeAndEarnsNothingRetroactively() public {
        _giveImd(ALICE, 100 ether);
        _giveImd(BOB, 150 ether);
        _giveImd(CAROL, 100 ether);
        _deposit(imdFarm, ALICE, 100 ether);
        _deposit(imdFarm, BOB, 100 ether);
        _deposit(imdFarm, CAROL, 100 ether);
        _matureStakes();

        _deposit(imdFarm, BOB, 50 ether);
        assertEq(imdFarm.eligibleStakeOf(BOB), 100 ether, "top-up reset eligible stake");
        assertEq(imdFarm.pendingStakeOf(BOB), 50 ether);
        assertEq(imdFarm.eligibleTotalStaked(), 300 ether);

        _withdraw(imdFarm, ALICE, 100 ether);
        // 9 ether shared by Bob's eligible 100 and Carol's 100; Bob's pending 50 is excluded.
        assertApproxEqAbs(imdFarm.pendingFees(BOB), 4.5 ether, 1);
        assertApproxEqAbs(imdFarm.pendingFees(CAROL), 4.5 ether, 1);

        _matureStakes();
        assertEq(imdFarm.eligibleStakeOf(BOB), 150 ether);
        assertApproxEqAbs(imdFarm.pendingFees(BOB), 4.5 ether, 1, "matured top-up credited a past fee");

        vm.prank(BOB);
        imdFarm.claimFees();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientBalance.selector, 151 ether, 150 ether));
        imdFarm.withdraw(151 ether);
        assertEq(imdFarm.pendingFees(BOB), 0, "double claim");
    }

    function test_partiallyWithdrawnPendingTrancheMaturesOnlyItsRemainder() public {
        _giveImd(ALICE, 100 ether);
        _giveImd(BOB, 100 ether);
        _deposit(imdFarm, ALICE, 100 ether);
        _matureStakes();
        _deposit(imdFarm, BOB, 100 ether);
        _withdraw(imdFarm, BOB, 40 ether);
        // Bob's pending withdrawal paid Alice, the only eligible other depositor.
        assertEq(imdFarm.pendingFees(ALICE), 3.6 ether);
        assertEq(imdFarm.pendingStakeOf(BOB), 60 ether);

        _matureStakes();
        assertEq(imdFarm.eligibleStakeOf(BOB), 60 ether);
        assertEq(imdFarm.eligibleTotalStaked(), 160 ether);
        assertEq(imdFarm.pendingFees(BOB), 0);
        _withdraw(imdFarm, ALICE, 100 ether);
        assertEq(imdFarm.pendingFees(BOB), 9 ether);
        assertEq(imdFarm.pendingFees(ALICE), 3.6 ether, "withdrawer earned from own fee");
    }

    /// @dev Bob deposits and withdraws at random times over several days while Alice, an eligible
    ///      depositor, keeps withdrawing small amounts. Bob's eligible stake must match a model where
    ///      each deposit matures at the start of the bucket after next and withdrawals consume the
    ///      newest pending stake first; Alice's fee must go to Bob exactly when Bob has eligible stake.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_eligibilityMatchesModel(uint256 seed) public {
        _giveImd(ALICE, 1_000 ether);
        _deposit(imdFarm, ALICE, 1_000 ether);
        _matureStakes();
        _giveImd(BOB, 1e30);

        uint256[] memory amt = new uint256[](16);
        uint256[] memory bkt = new uint256[](16);
        uint256 n;
        uint256 bal;
        for (uint256 step; step < 16; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            vm.warp(block.timestamp + (r % 30 hours));
            uint256 cur = block.timestamp / 1 days;
            if (bal == 0 || (r >> 64) % 3 != 0) {
                uint256 a = bound(r >> 128, 1, 1e24);
                _deposit(imdFarm, BOB, a);
                amt[n] = a;
                bkt[n] = cur;
                ++n;
                bal += a;
            } else {
                uint256 a = bound(r >> 128, 1, bal);
                _withdraw(imdFarm, BOB, a);
                bal -= a;
                uint256 left = a;
                for (uint256 k = n; k > 0 && left > 0; --k) {
                    if (cur >= bkt[k - 1] + 2 || amt[k - 1] == 0) continue;
                    uint256 take = left < amt[k - 1] ? left : amt[k - 1];
                    amt[k - 1] -= take;
                    left -= take;
                }
            }
            uint256 pendingModel;
            for (uint256 k; k < n; ++k) {
                if (cur < bkt[k] + 2) pendingModel += amt[k];
            }
            assertEq(imdFarm.balanceOf(BOB), bal, "balance");
            assertEq(imdFarm.pendingStakeOf(BOB), pendingModel, "pending stake differs from model");
            assertEq(imdFarm.eligibleTotalStaked(), imdFarm.eligibleStakeOf(BOB) + imdFarm.eligibleStakeOf(ALICE));

            uint256 bobFees = imdFarm.pendingFees(BOB);
            uint256 treasuryBefore = imd.balanceOf(address(treasury));
            _withdraw(imdFarm, ALICE, 1 ether);
            uint256 toTreasury = imd.balanceOf(address(treasury)) - treasuryBefore;
            if (bal - pendingModel == 0) {
                assertEq(toTreasury, 0.1 ether, "fee went to pending stake");
                assertEq(imdFarm.pendingFees(BOB), bobFees, "pending stake earned a fee");
            } else {
                assertEq(toTreasury, 0.01 ether, "eligible other ignored");
                assertApproxEqAbs(imdFarm.pendingFees(BOB) - bobFees, 0.09 ether, 1e7, "Bob's share");
                assertLe(imdFarm.pendingFees(BOB) - bobFees, 0.09 ether);
            }
        }
        // Everything owed is payable.
        assertGe(
            imd.balanceOf(address(imdFarm)),
            imdFarm.totalStaked() + imdFarm.pendingFees(ALICE) + imdFarm.pendingFees(BOB)
        );
    }

    // ---------------------------------------------------------------------------------------
    // Emissions renounce: exact sweep, nothing owed touched, nothing stranded
    // ---------------------------------------------------------------------------------------

    /// @dev Uncommitted reserve the farm would hold after accruing now: emissions over a span with
    ///      nobody staked return to the reserve on the next update.
    function _reserveAfterAccrual(LockerFarm farm) internal view returns (uint256) {
        uint256 recycled =
            farm.totalStaked() == 0 ? (farm.lastTimeRewardApplicable() - farm.lastUpdateTime()) * farm.rewardRate() : 0;
        return farm.rewardReserve() + recycled;
    }

    /// @dev The renounce happens at an arbitrary point: before, during or after the epoch, with a
    ///      staker present, gone, or never there. It must move exactly the post-accrual reserve to the
    ///      Treasury and leave rewards owed and the rest of the epoch in place; afterwards every LOCKER
    ///      the farm holds must reach the staker or (permissionlessly) the Treasury, bar rounding dust.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_renounceSweepsExactlyAndStrandsNothing(
        uint256 funded,
        uint256 committed,
        uint256 stake,
        uint256 tStake,
        uint256 tUnstake,
        uint256 tRenounce
    ) public {
        funded = bound(funded, EPOCH, 50_000_000 ether);
        committed = bound(committed, EPOCH, funded);
        stake = bound(stake, 0, 1_000_000 ether);
        _fund(imdFarm, funded);
        _startEpoch(imdFarm, committed);
        uint256 finish = imdFarm.periodFinish();

        if (stake > 0) {
            vm.warp(block.timestamp + bound(tStake, 0, 35 days));
            _giveImd(ALICE, stake);
            _deposit(imdFarm, ALICE, stake);
            // A third of the runs leave the farm empty again before the renounce.
            if (tUnstake % 3 == 0) {
                vm.warp(block.timestamp + bound(tUnstake, 0, 10 days));
                vm.prank(ALICE);
                imdFarm.exit();
            }
        }
        vm.warp(block.timestamp + bound(tRenounce, 0, 40 days));

        uint256 expected = _reserveAfterAccrual(imdFarm);
        uint256 earnedBefore = imdFarm.earned(ALICE);
        uint256 remaining = imdFarm.remainingEpochRewards();
        uint256 rate = imdFarm.rewardRate();
        uint256 treasuryBefore = locker.balanceOf(address(treasury));

        vm.prank(OWNER);
        imdFarm.renounceEmissionsManager();

        assertEq(locker.balanceOf(address(treasury)) - treasuryBefore, expected, "sweep != reserve after accrual");
        assertEq(imdFarm.rewardReserve(), 0, "reserve left behind");
        assertEq(imdFarm.earned(ALICE), earnedBefore, "accrued rewards touched");
        assertEq(imdFarm.remainingEpochRewards(), remaining, "running epoch touched");
        assertEq(imdFarm.rewardRate(), rate);
        assertEq(imdFarm.periodFinish(), finish);
        assertEq(imdFarm.emissionsManager(), address(0));
        assertGe(locker.balanceOf(address(imdFarm)), remaining + earnedBefore, "epoch no longer backed");

        // Run the epoch out. The staker leaves with everything earned; a stranger returns whatever
        // was recycled after the renounce.
        vm.warp(finish + 1);
        uint256 lockerBefore = locker.balanceOf(ALICE);
        uint256 owed = imdFarm.earned(ALICE);
        vm.prank(ALICE);
        imdFarm.exit();
        assertEq(locker.balanceOf(ALICE) - lockerBefore, owed);
        uint256 recycled = _reserveAfterAccrual(imdFarm);
        if (recycled > 0) {
            vm.prank(BOB);
            imdFarm.returnUncommittedRewards(recycled);
        }
        assertEq(imdFarm.rewardReserve(), 0);
        // Per-share rounding is the only thing that may stay behind: under a wei per update per
        // 1e18 staked, plus a wei per checkpoint.
        assertLe(locker.balanceOf(address(imdFarm)), 8 * (stake / 1e18 + 1), "LOCKER stranded after renounce");
    }

    /// @dev A pending offer cannot be accepted once the holder renounces, even in the same block.
    function test_pendingOffereeCannotAcceptAfterRenounce() public {
        _fund(imdFarm, 30_000 ether);
        vm.startPrank(OWNER);
        imdFarm.setEmissionsManager(CAROL);
        imdFarm.renounceEmissionsManager();
        vm.stopPrank();
        assertEq(locker.balanceOf(address(treasury)), 30_000 ether, "unused funding swept to the Treasury");
        vm.prank(CAROL);
        vm.expectRevert(LockerFarm.NotPendingEmissionsManager.selector);
        imdFarm.acceptEmissionsManager();
        // Renouncing twice is impossible: the role no longer exists.
        vm.prank(OWNER);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.renounceEmissionsManager();
        vm.prank(address(0));
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.renounceEmissionsManager();
    }

    /// @dev Only the emissions manager may renounce; the guardian, the Treasury, a stranger and the
    ///      factory cannot trigger the sweep.
    function test_onlyEmissionsManagerCanRenounce() public {
        _fund(imdFarm, 1 ether);
        address[4] memory callers = [BOB, address(treasury), address(factory), address(0)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
            imdFarm.renounceEmissionsManager();
        }
        vm.prank(OWNER);
        imdFarm.setGuardian(BOB);
        vm.prank(BOB);
        imdFarm.acceptGuardian();
        vm.prank(BOB);
        vm.expectRevert(LockerFarm.NotEmissionsManager.selector);
        imdFarm.renounceEmissionsManager();
        assertEq(imdFarm.emissionsManager(), OWNER);
        assertEq(imdFarm.rewardReserve(), 1 ether);
    }

    function _seed(address who, uint256 amount) internal {
        _giveImd(who, amount);
        _deposit(imdFarm, who, amount);
    }

    function _checkShare(address who, uint256 stake, uint256 others, uint256 redistributed) internal view {
        if (stake == 0) {
            assertEq(imdFarm.pendingFees(who), 0);
            return;
        }
        uint256 exact = redistributed * stake / others;
        uint256 got = imdFarm.pendingFees(who);
        assertLe(got, exact + 1, "share above proportional");
        assertApproxEqAbs(got, exact, 2 + stake / 1e18, "share not proportional");
    }
}
