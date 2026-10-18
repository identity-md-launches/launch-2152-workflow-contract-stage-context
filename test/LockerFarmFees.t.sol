// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmTestBase} from "./FarmTestBase.sol";
import {LockerFarm} from "../src/LockerFarm.sol";

/// @notice Deposits, withdrawals and the 10% withdrawal fee (9% redistributed, 1% Treasury).
contract LockerFarmFeesTest is FarmTestBase {
    function setUp() public override {
        super.setUp();
        _giveImd(ALICE, 1_000_000e18);
        _giveImd(BOB, 1_000_000e18);
        _giveImd(CAROL, 1_000_000e18);
    }

    // ------------------------------------------------------------------ deposits

    function test_depositHasNoFeeAndTracksPrincipal() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        assertEq(imdFarm.balanceOf(ALICE), 1_000e18);
        assertEq(imdFarm.totalStaked(), 1_000e18);
        assertEq(imd.balanceOf(address(imdFarm)), 1_000e18);
        assertEq(imd.balanceOf(ALICE), 1_000_000e18 - 1_000e18);
        assertEq(imd.balanceOf(address(treasury)), 0);
    }

    function test_depositZeroReverts() public {
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        vm.prank(ALICE);
        imdFarm.deposit(0);
    }

    function test_depositWithoutApprovalReverts() public {
        address nobody = address(0x9999);
        imd.mint(nobody, 10e18);
        vm.expectRevert();
        vm.prank(nobody);
        imdFarm.deposit(10e18);
    }

    // ------------------------------------------------------------------ withdrawals

    function test_partialWithdrawalSplitsFeeAndExcludesWithdrawer() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 3_000e18);
        _matureStakes();

        uint256 aliceBefore = imd.balanceOf(ALICE);
        vm.expectEmit(true, false, false, true);
        emit LockerFarm.Withdrawn(ALICE, 400e18, 360e18, 36e18, 4e18);
        _withdraw(imdFarm, ALICE, 400e18);

        assertEq(imd.balanceOf(ALICE) - aliceBefore, 360e18, "alice receives 90%");
        assertEq(imd.balanceOf(address(treasury)), 4e18, "treasury gets 1%");
        assertEq(imdFarm.pendingFees(BOB), 36e18, "bob gets the 9%");
        assertEq(imdFarm.pendingFees(ALICE), 0, "alice earns nothing from her own fee");
        assertEq(imdFarm.balanceOf(ALICE), 600e18);
        assertEq(imdFarm.totalStaked(), 3_600e18);
        assertEq(imdFarm.totalFeesRedistributed(), 36e18);
        assertEq(imdFarm.totalFeesToTreasury(), 4e18);
    }

    function test_feeIsProportionalAmongOtherDepositors() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _deposit(imdFarm, CAROL, 3_000e18);
        _matureStakes();

        _withdraw(imdFarm, ALICE, 1_000e18);
        // 90 redistributed over Bob (1/4) and Carol (3/4).
        assertEq(imdFarm.pendingFees(BOB), 22.5e18);
        assertEq(imdFarm.pendingFees(CAROL), 67.5e18);
        assertEq(imdFarm.pendingFees(ALICE), 0);
        assertEq(imd.balanceOf(address(treasury)), 10e18);
    }

    function test_soleDepositorPaysEverythingToTreasury() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        uint256 before = imd.balanceOf(ALICE);
        _withdraw(imdFarm, ALICE, 1_000e18);
        assertEq(imd.balanceOf(ALICE) - before, 900e18);
        assertEq(imd.balanceOf(address(treasury)), 100e18);
        assertEq(imdFarm.totalStaked(), 0);
        assertEq(imd.balanceOf(address(imdFarm)), 0, "nothing stranded");
    }

    function test_withdrawMoreThanBalanceReverts() public {
        _deposit(imdFarm, ALICE, 100e18);
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientBalance.selector, 101e18, 100e18));
        _withdraw(imdFarm, ALICE, 101e18);
    }

    function test_withdrawZeroReverts() public {
        vm.expectRevert(LockerFarm.ZeroAmount.selector);
        _withdraw(imdFarm, ALICE, 0);
    }

    function test_withdrawWithNothingDepositedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LockerFarm.InsufficientBalance.selector, 1, 0));
        _withdraw(imdFarm, BOB, 1);
    }

    function test_previewWithdrawMatchesExecution() public {
        _deposit(imdFarm, ALICE, 777e18);
        _deposit(imdFarm, BOB, 1_234e18);
        _matureStakes();
        (uint256 payout, uint256 redistributed, uint256 toTreasury) = imdFarm.previewWithdraw(ALICE, 333e18);
        uint256 before = imd.balanceOf(ALICE);
        uint256 treasuryBefore = imd.balanceOf(address(treasury));
        _withdraw(imdFarm, ALICE, 333e18);
        assertEq(imd.balanceOf(ALICE) - before, payout);
        assertEq(imd.balanceOf(address(treasury)) - treasuryBefore, toTreasury);
        assertLe(imdFarm.pendingFees(BOB), redistributed);
        assertApproxEqAbs(imdFarm.pendingFees(BOB), redistributed, 1_234e18 / 1e18 + 1, "per-share rounding only");
        assertEq(payout + redistributed + toTreasury, 333e18);
    }

    // ------------------------------------------------------------------ fee claims

    function test_feesClaimableImmediatelyWithoutExtraFee() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _matureStakes();
        _withdraw(imdFarm, ALICE, 1_000e18);
        assertEq(imdFarm.pendingFees(BOB), 90e18);

        uint256 before = imd.balanceOf(BOB);
        vm.prank(BOB);
        imdFarm.claimFees();
        assertEq(imd.balanceOf(BOB) - before, 90e18, "full 9% paid, no further fee");
        assertEq(imdFarm.pendingFees(BOB), 0);
        assertEq(imdFarm.balanceOf(BOB), 1_000e18, "principal untouched");
    }

    function test_feesRemainClaimableAfterFullWithdrawal() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 3_000e18);
        _matureStakes();
        _withdraw(imdFarm, ALICE, 400e18); // Bob earns 36
        _withdraw(imdFarm, BOB, 3_000e18); // Bob leaves; Alice earns 270
        assertEq(imdFarm.balanceOf(BOB), 0);
        assertEq(imdFarm.pendingFees(BOB), 36e18, "owed fees survive a full exit");
        assertEq(imdFarm.pendingFees(ALICE), 270e18);

        uint256 before = imd.balanceOf(BOB);
        vm.prank(BOB);
        imdFarm.claimFees();
        assertEq(imd.balanceOf(BOB) - before, 36e18);
    }

    function test_doubleClaimFeesPaysNothingTwice() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _matureStakes();
        _withdraw(imdFarm, ALICE, 1_000e18);
        vm.startPrank(BOB);
        imdFarm.claimFees();
        uint256 after1 = imd.balanceOf(BOB);
        imdFarm.claimFees();
        vm.stopPrank();
        assertEq(imd.balanceOf(BOB), after1);
    }

    function test_withdrawerKeepsFeesEarnedBeforeOwnWithdrawal() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _matureStakes();
        _withdraw(imdFarm, BOB, 500e18); // Alice earns 45
        assertEq(imdFarm.pendingFees(ALICE), 45e18);
        _withdraw(imdFarm, ALICE, 500e18); // Alice's own fee goes to Bob only
        assertEq(imdFarm.pendingFees(ALICE), 45e18, "earlier fees kept, own fee excluded");
        assertEq(imdFarm.pendingFees(BOB), 45e18);
    }

    function test_lateDepositorDoesNotEarnEarlierFees() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _matureStakes();
        _withdraw(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, CAROL, 5_000e18);
        assertEq(imdFarm.pendingFees(CAROL), 0);
        assertEq(imdFarm.pendingFees(BOB), 90e18);
    }

    function test_exitWithdrawsAllAndClaimsFees() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _matureStakes();
        _withdraw(imdFarm, ALICE, 500e18); // Bob earns 45
        uint256 before = imd.balanceOf(BOB);
        vm.prank(BOB);
        imdFarm.exit();
        // 900 principal payout + 45 fees
        assertEq(imd.balanceOf(BOB) - before, 945e18);
        assertEq(imdFarm.balanceOf(BOB), 0);
        assertEq(imdFarm.pendingFees(BOB), 0);
        assertEq(imdFarm.pendingFees(ALICE), 90e18);
    }

    // ------------------------------------------------------------------ conservation

    function testFuzz_withdrawFeeConservesFunds(uint256 a, uint256 b, uint256 w) public {
        a = bound(a, 1, 1_000_000e18);
        b = bound(b, 1, 1_000_000e18);
        w = bound(w, 1, a);
        _deposit(imdFarm, ALICE, a);
        _deposit(imdFarm, BOB, b);
        _matureStakes();

        uint256 aliceBefore = imd.balanceOf(ALICE);
        _withdraw(imdFarm, ALICE, w);
        uint256 payout = imd.balanceOf(ALICE) - aliceBefore;
        uint256 toTreasury = imd.balanceOf(address(treasury));
        uint256 bobFees = imdFarm.pendingFees(BOB);

        uint256 fee = (w + 9) / 10; // rounds up
        uint256 share = w * 900 / 10_000;
        assertEq(payout, w - fee, "payout is 90%, fee rounded up");
        assertEq(toTreasury, fee - share, "treasury gets exactly its 1%");
        assertLe(bobFees, share, "bob never gets more than the 9%");
        assertLe(share - bobFees, b / 1e18 + 1, "bob gets the 9% minus at most per-share rounding");
        // Conservation: what left Alice's stake is payout + Bob's fee + Treasury fee + dust kept by the farm.
        uint256 dust = w - payout - bobFees - toTreasury;
        assertEq(imd.balanceOf(address(imdFarm)), imdFarm.totalStaked() + bobFees + dust, "farm holds principal + fees");
        assertGe(imd.balanceOf(address(imdFarm)), imdFarm.totalStaked() + bobFees, "solvent");
        assertEq(imdFarm.totalStaked(), a - w + b);
        assertEq(imdFarm.pendingFees(ALICE), 0);
    }

    function testFuzz_manyDepositorsStayClaimable(uint256 seed) public {
        address[3] memory users = [ALICE, BOB, CAROL];
        for (uint256 i; i < 3; ++i) {
            uint256 amt = bound(uint256(keccak256(abi.encode(seed, i))), 1e6, 500_000e18);
            _deposit(imdFarm, users[i], amt);
        }
        _matureStakes();
        for (uint256 i; i < 3; ++i) {
            uint256 bal = imdFarm.balanceOf(users[i]);
            uint256 w = bound(uint256(keccak256(abi.encode(seed, i, "w"))), 1, bal);
            _withdraw(imdFarm, users[i], w);
        }
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            owed += imdFarm.pendingFees(users[i]);
        }
        assertGe(imd.balanceOf(address(imdFarm)), imdFarm.totalStaked() + owed);
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            imdFarm.exit();
        }
        assertEq(imdFarm.totalStaked(), 0);
        // Per-share rounding leaves at most ~others/1e18 wei per redistribution in the farm.
        assertLe(imd.balanceOf(address(imdFarm)), 1e7, "only rounding dust can remain");
    }
}
