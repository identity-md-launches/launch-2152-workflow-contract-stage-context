// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmTestBase} from "./FarmTestBase.sol";
import {LockerFarm} from "../src/LockerFarm.sol";

/// @notice The time dimension of fee eligibility: stake deposited in one bucket shares in withdrawal
///         fees only from the start of the bucket after next. Covers the sole-depositor rule against
///         dust and same-block wallets, just-in-time deposits, pending stake semantics and the
///         rounding of the fee itself.
contract LockerFarmFeeEligibilityTest is FarmTestBase {
    address internal constant WHALE = address(0xBEEF);
    address internal constant WHALE_ALT = address(0xA17);
    address internal constant SNIPER = address(0x5A1);

    uint256 internal constant PERIOD = 1 days;

    function setUp() public override {
        super.setUp();
        _giveImd(ALICE, 1_000_000e18);
        _giveImd(BOB, 1_000_000e18);
        _giveImd(CAROL, 1_000_000e18);
        _giveImd(WHALE, 1_000_000e18);
        _giveImd(WHALE_ALT, 1e18);
        _giveImd(SNIPER, 1_000_000e18);
        // Start at a bucket boundary so the arithmetic below is easy to follow.
        vm.warp((block.timestamp / PERIOD) * PERIOD);
    }

    // ------------------------------------------------------------------ the reported defect

    /// A sole depositor cannot route the Treasury's 10% back to itself through a dust wallet staked in
    /// the same bucket (the reviewer's scenario).
    function test_soleDepositorDustAltWalletDoesNotCaptureFee() public {
        _deposit(imdFarm, WHALE, 1_000_000e18);
        _deposit(imdFarm, WHALE_ALT, 1);
        _withdraw(imdFarm, WHALE, 1_000_000e18);
        vm.prank(WHALE_ALT);
        imdFarm.claimFees();
        assertEq(imd.balanceOf(address(treasury)), 100_000e18, "the whole 10% reaches the Treasury");
        assertEq(imdFarm.pendingFees(WHALE_ALT), 0);
        assertEq(imd.balanceOf(WHALE_ALT), 1e18 - 1);
        assertEq(imdFarm.totalFeesRedistributed(), 0);
    }

    /// Same, when the whale's stake is old and only the dust wallet is fresh.
    function test_freshDustWalletIsNotAnEligibleOtherDepositor() public {
        _deposit(imdFarm, WHALE, 1_000_000e18);
        _matureStakes();
        _deposit(imdFarm, WHALE_ALT, 1); // front-run in the withdrawal's block
        _withdraw(imdFarm, WHALE, 1_000_000e18);
        assertEq(imd.balanceOf(address(treasury)), 100_000e18);
        assertEq(imdFarm.pendingFees(WHALE_ALT), 0);
        // One bucket later it is still pending; two buckets later it is eligible but the fee is gone.
        vm.warp(block.timestamp + PERIOD);
        assertEq(imdFarm.pendingFees(WHALE_ALT), 0);
        assertEq(imdFarm.pendingStakeOf(WHALE_ALT), 1);
        vm.warp(block.timestamp + PERIOD);
        assertEq(imdFarm.pendingFees(WHALE_ALT), 0);
        assertEq(imdFarm.pendingStakeOf(WHALE_ALT), 0);
    }

    /// The just-in-time variant: a large deposit in the withdrawal's block earns nothing and pays
    /// its own fee on the way out; the long-term depositor keeps the whole 9%.
    function test_justInTimeDepositorEarnsNothingAndPaysToLeave() public {
        _deposit(imdFarm, WHALE, 1_000_000e18);
        _deposit(imdFarm, ALICE, 100_000e18);
        _matureStakes();
        _deposit(imdFarm, SNIPER, 200_000e18);
        _withdraw(imdFarm, WHALE, 1_000_000e18);

        assertEq(imdFarm.pendingFees(ALICE), 90_000e18, "alice receives the full 9%");
        assertEq(imdFarm.pendingFees(SNIPER), 0);
        assertEq(imd.balanceOf(address(treasury)), 10_000e18);

        vm.prank(SNIPER);
        imdFarm.exit();
        assertEq(imd.balanceOf(SNIPER), 1_000_000e18 - 20_000e18, "sniper is down its own fee");
        // The sniper's exit fee, in turn, goes to the only eligible other depositor: Alice.
        assertEq(imdFarm.pendingFees(ALICE), 90_000e18 + 18_000e18);
    }

    // ------------------------------------------------------------------ pending stake semantics

    function test_pendingStakeStillEarnsLockerEmissions() public {
        _fund(imdFarm, 3_000e18);
        _deposit(imdFarm, ALICE, 100e18);
        _startEpoch(imdFarm, 3_000e18);
        vm.warp(block.timestamp + 1 hours);
        assertGt(imdFarm.earned(ALICE), 0, "emissions have no eligibility delay");
        assertEq(imdFarm.pendingStakeOf(ALICE), 100e18);
        assertEq(imdFarm.eligibleStakeOf(ALICE), 0);
        assertEq(imdFarm.eligibleTotalStaked(), 0);
    }

    function test_pendingStakeCanBeWithdrawnAndPaysTheFee() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _matureStakes();
        _deposit(imdFarm, BOB, 1_000e18);
        uint256 before = imd.balanceOf(BOB);
        _withdraw(imdFarm, BOB, 1_000e18);
        assertEq(imd.balanceOf(BOB) - before, 900e18);
        assertEq(imdFarm.pendingFees(ALICE), 90e18, "eligible alice gets the 9%");
        assertEq(imd.balanceOf(address(treasury)), 10e18);
        assertEq(imdFarm.pendingStakeOf(BOB), 0);
        assertEq(imdFarm.eligibleTotalStaked(), 1_000e18);
    }

    function test_stakeMaturesAtTheStartOfTheBucketAfterNext() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _matureStakes();
        uint256 depositTime = block.timestamp + 10 hours;
        vm.warp(depositTime);
        _deposit(imdFarm, BOB, 1_000e18);
        uint256 eligibleAt = ((depositTime / PERIOD) + 2) * PERIOD;
        assertEq(imdFarm.feeEligibilityStart(), eligibleAt);

        vm.warp(eligibleAt - 1);
        _withdraw(imdFarm, ALICE, 100e18); // Bob still pending: 10 to Treasury
        assertEq(imdFarm.pendingFees(BOB), 0);
        assertEq(imd.balanceOf(address(treasury)), 10e18);
        assertEq(imdFarm.eligibleTotalStaked(), 900e18);

        vm.warp(eligibleAt);
        assertEq(imdFarm.eligibleTotalStaked(), 1_900e18);
        assertEq(imdFarm.eligibleStakeOf(BOB), 1_000e18);
        _withdraw(imdFarm, ALICE, 100e18); // Bob eligible: 9 to Bob, 1 to Treasury
        assertEq(imdFarm.pendingFees(BOB), 9e18);
        assertEq(imd.balanceOf(address(treasury)), 11e18);
    }

    /// A matured tranche is credited exactly once, from its maturity onward, even when the account
    /// never interacted between deposit and claim.
    function test_maturedTrancheIsCreditedOnceFromMaturity() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _matureStakes();
        _withdraw(imdFarm, ALICE, 100e18); // both eligible, Bob earns 9
        _deposit(imdFarm, CAROL, 1_000e18); // pending
        _withdraw(imdFarm, ALICE, 100e18); // Carol pending: Bob earns 9 more
        assertEq(imdFarm.pendingFees(CAROL), 0);
        _matureStakes(); // Carol matures without touching the farm
        _withdraw(imdFarm, ALICE, 100e18); // Bob and Carol split 9
        assertEq(imdFarm.pendingFees(BOB), 22.5e18);
        assertEq(imdFarm.pendingFees(CAROL), 4.5e18);
        vm.prank(CAROL);
        imdFarm.claimFees();
        assertEq(imd.balanceOf(CAROL), 1_000_000e18 - 1_000e18 + 4.5e18);
        assertEq(imdFarm.pendingFees(CAROL), 0);
        // Solvent: principal plus Bob's unclaimed fees plus rounding dust only.
        assertGe(imd.balanceOf(address(imdFarm)), imdFarm.totalStaked() + imdFarm.pendingFees(BOB));
    }

    /// Two deposits on consecutive days keep separate tranches and mature one after the other.
    function test_consecutiveDayDepositsMatureSeparately() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _matureStakes();
        _deposit(imdFarm, BOB, 100e18); // bucket k
        vm.warp(block.timestamp + PERIOD);
        _deposit(imdFarm, BOB, 300e18); // bucket k+1
        assertEq(imdFarm.pendingStakeOf(BOB), 400e18);
        vm.warp(block.timestamp + PERIOD); // bucket k+2: first tranche eligible
        assertEq(imdFarm.pendingStakeOf(BOB), 300e18);
        assertEq(imdFarm.eligibleStakeOf(BOB), 100e18);
        _withdraw(imdFarm, ALICE, 100e18); // 9 over Bob's 100 eligible
        assertEq(imdFarm.pendingFees(BOB), 9e18);
        vm.warp(block.timestamp + PERIOD); // bucket k+3: second tranche eligible
        assertEq(imdFarm.pendingStakeOf(BOB), 0);
        _withdraw(imdFarm, ALICE, 100e18);
        assertEq(imdFarm.pendingFees(BOB), 18e18);
        assertEq(imdFarm.eligibleTotalStaked(), 800e18 + 400e18);
    }

    /// Withdrawing takes pending stake first, so a top-up does not cost eligible stake.
    function test_withdrawalComesOutOfPendingStakeFirst() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _deposit(imdFarm, BOB, 1_000e18);
        _matureStakes();
        _deposit(imdFarm, BOB, 500e18); // pending top-up
        _withdraw(imdFarm, BOB, 300e18);
        assertEq(imdFarm.pendingStakeOf(BOB), 200e18);
        assertEq(imdFarm.eligibleStakeOf(BOB), 1_000e18);
        _withdraw(imdFarm, BOB, 700e18);
        assertEq(imdFarm.pendingStakeOf(BOB), 0);
        assertEq(imdFarm.eligibleStakeOf(BOB), 500e18);
        assertEq(imdFarm.eligibleTotalStaked(), 1_500e18);
        // Bob never earned from his own fees; Alice earned 9% of both withdrawals.
        assertEq(imdFarm.pendingFees(BOB), 0);
        assertEq(imdFarm.pendingFees(ALICE), 27e18 + 63e18);
    }

    function test_previewMatchesExecutionWithPendingStake() public {
        _deposit(imdFarm, ALICE, 1_000e18);
        _matureStakes();
        _deposit(imdFarm, BOB, 1_000e18);
        // Alice is the only eligible depositor, so her own withdrawal has no eligible other.
        (uint256 payout, uint256 redistributed, uint256 toTreasury) = imdFarm.previewWithdraw(ALICE, 100e18);
        assertEq(payout, 90e18);
        assertEq(redistributed, 0);
        assertEq(toTreasury, 10e18);
        uint256 before = imd.balanceOf(address(treasury));
        _withdraw(imdFarm, ALICE, 100e18);
        assertEq(imd.balanceOf(address(treasury)) - before, toTreasury);
        // Bob's withdrawal, with Alice eligible, redistributes.
        (payout, redistributed, toTreasury) = imdFarm.previewWithdraw(BOB, 100e18);
        assertEq(redistributed, 9e18);
        assertEq(toTreasury, 1e18);
        _withdraw(imdFarm, BOB, 100e18);
        assertEq(imdFarm.pendingFees(ALICE), 9e18);
    }

    // ------------------------------------------------------------------ fee rounding

    function test_tinyWithdrawalsStillPayTheFee() public {
        _deposit(imdFarm, ALICE, 100);
        _deposit(imdFarm, BOB, 100);
        _matureStakes();
        uint256 before = imd.balanceOf(ALICE);
        _withdraw(imdFarm, ALICE, 9);
        assertEq(imd.balanceOf(ALICE) - before, 8, "fee rounds up to 1 wei");
        assertEq(imdFarm.totalFeesToTreasury(), 1);
        assertEq(imdFarm.totalFeesRedistributed(), 0);
        _withdraw(imdFarm, ALICE, 19);
        // fee = ceil(1.9) = 2, redistributed = floor(1.71) = 1, treasury = 1
        assertEq(imdFarm.totalFeesToTreasury(), 2);
        assertEq(imdFarm.totalFeesRedistributed(), 1);
        assertEq(imd.balanceOf(ALICE) - before, 8 + 17);
    }

    function testFuzz_feeRoundsAgainstTheWithdrawer(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        _deposit(imdFarm, ALICE, amount);
        _deposit(imdFarm, BOB, 1e18);
        _matureStakes();
        uint256 before = imd.balanceOf(ALICE);
        _withdraw(imdFarm, ALICE, amount);
        uint256 payout = imd.balanceOf(ALICE) - before;
        uint256 fee = amount - payout;
        assertGe(fee * 10, amount, "fee is at least 10%");
        assertLt(fee * 10, amount + 10, "and at most 10% rounded up");
        assertGe(imdFarm.totalFeesToTreasury(), 1, "the Treasury always gets at least 1 wei");
        assertEq(imdFarm.totalFeesToTreasury() + imdFarm.totalFeesRedistributed(), fee);
    }

    // ------------------------------------------------------------------ conservation under the delay

    function testFuzz_eligibilityNeverBreaksSolvency(uint256 seed) public {
        address[4] memory users = [ALICE, BOB, CAROL, WHALE];
        for (uint256 round; round < 4; ++round) {
            for (uint256 i; i < 4; ++i) {
                uint256 r = uint256(keccak256(abi.encode(seed, round, i)));
                uint256 bal = imdFarm.balanceOf(users[i]);
                if (r % 3 == 0 && bal > 0) {
                    _withdraw(imdFarm, users[i], bound(r >> 8, 1, bal));
                } else {
                    _deposit(imdFarm, users[i], bound(r >> 8, 1, 10_000e18));
                }
                vm.warp(block.timestamp + bound(r >> 128, 0, 2 * PERIOD));
            }
            uint256 owed;
            uint256 pending;
            for (uint256 i; i < 4; ++i) {
                owed += imdFarm.pendingFees(users[i]);
                pending += imdFarm.pendingStakeOf(users[i]);
            }
            assertGe(imd.balanceOf(address(imdFarm)), imdFarm.totalStaked() + owed, "solvent");
            assertEq(imdFarm.eligibleTotalStaked() + pending, imdFarm.totalStaked(), "eligible + pending = staked");
        }
        for (uint256 i; i < 4; ++i) {
            vm.prank(users[i]);
            imdFarm.exit();
        }
        assertEq(imdFarm.totalStaked(), 0);
        assertEq(imdFarm.eligibleTotalStaked(), 0);
        assertLe(imd.balanceOf(address(imdFarm)), 1e7, "only rounding dust remains");
    }
}
