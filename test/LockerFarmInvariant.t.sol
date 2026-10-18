// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {LockerTreasury} from "../src/LockerTreasury.sol";

/// @dev Drives a LOCKER-staking farm (staking token == reward token, the hardest case for
///      accounting) through random deposits, withdrawals, claims, funding and schedule changes.
contract FarmHandler is Test {
    LockerFarm public farm;
    LaunchToken public locker;
    address public owner;
    address[] public actors;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawnNet;
    uint256 public ghostFeesClaimed;
    uint256 public ghostRewardsClaimed;
    uint256 public ghostFunded;
    uint256 public ghostReturned;

    constructor(LockerFarm farm_, LaunchToken locker_, address owner_) {
        farm = farm_;
        locker = locker_;
        owner = owner_;
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA4E));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 10_000_000e18);
        if (locker.balanceOf(who) < amount) {
            vm.prank(owner);
            locker.transfer(who, amount);
        }
        vm.startPrank(who);
        locker.approve(address(farm), amount);
        farm.deposit(amount);
        vm.stopPrank();
        ghostDeposited += amount;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 bal = farm.balanceOf(who);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 before = locker.balanceOf(who);
        vm.prank(who);
        farm.withdraw(amount);
        ghostWithdrawnNet += locker.balanceOf(who) - before;
    }

    function claimFees(uint256 seed) external {
        address who = _actor(seed);
        uint256 before = locker.balanceOf(who);
        vm.prank(who);
        farm.claimFees();
        ghostFeesClaimed += locker.balanceOf(who) - before;
    }

    function claimRewards(uint256 seed) external {
        address who = _actor(seed);
        uint256 before = locker.balanceOf(who);
        vm.prank(who);
        farm.claimRewards();
        ghostRewardsClaimed += locker.balanceOf(who) - before;
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        vm.startPrank(owner);
        locker.approve(address(farm), amount);
        farm.fundRewards(amount);
        vm.stopPrank();
        ghostFunded += amount;
    }

    function startEpoch(uint256 amount) external {
        uint256 reserve = farm.rewardReserve();
        if (reserve < 30 days) return;
        amount = bound(amount, 30 days, reserve);
        vm.prank(owner);
        farm.startEpoch(amount);
    }

    function boost(uint256 amount) external {
        if (block.timestamp >= farm.periodFinish()) return;
        uint256 reserve = farm.rewardReserve();
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        vm.prank(owner);
        farm.boostEmissions(amount);
    }

    function setRate(uint256 rate) external {
        if (block.timestamp >= farm.periodFinish()) return;
        uint256 remaining = farm.periodFinish() - block.timestamp;
        uint256 available = farm.rewardReserve() + farm.rewardRate() * remaining;
        rate = bound(rate, 0, available / remaining);
        vm.prank(owner);
        farm.setRewardRate(rate);
    }

    function returnUncommitted(uint256 amount) external {
        uint256 reserve = farm.rewardReserve();
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        vm.prank(owner);
        farm.returnUncommittedRewards(amount);
        ghostReturned += amount;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 10 days));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract LockerFarmInvariantTest is Test {
    address internal constant OWNER = address(0xDEA11b3A70b77134424d436f6eb455f1Abbd4449);

    LaunchToken internal locker;
    LockerTreasury internal treasury;
    LockerFarm internal farm;
    FarmHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(OWNER);
        locker = new LaunchToken();
        treasury = new LockerTreasury(OWNER, address(locker));
        farm = new LockerFarm(address(locker), address(locker), address(treasury), OWNER);
        handler = new FarmHandler(farm, locker, OWNER);
        targetContract(address(handler));
    }

    /// @dev The farm always holds enough LOCKER to pay every principal, every pending fee reward,
    ///      every accrued LOCKER reward, the uncommitted reserve and the rest of the running epoch.
    function invariant_farmIsSolvent() public view {
        uint256 owed = farm.totalStaked() + farm.rewardReserve() + farm.remainingEpochRewards();
        uint256 sumBalances;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            owed += farm.pendingFees(a) + farm.earned(a);
            sumBalances += farm.balanceOf(a);
        }
        assertGe(locker.balanceOf(address(farm)), owed, "farm insolvent");
        assertEq(sumBalances, farm.totalStaked(), "principal accounting drift");
    }

    /// @dev LOCKER is conserved between users, the farm and the Treasury: everything that went in
    ///      either stays in the farm, came back to a user, or went to the Treasury.
    function invariant_conservation() public view {
        uint256 inflow = handler.ghostDeposited() + handler.ghostFunded();
        uint256 outflow = handler.ghostWithdrawnNet() + handler.ghostFeesClaimed() + handler.ghostRewardsClaimed()
            + handler.ghostReturned() + farm.totalFeesToTreasury();
        assertEq(locker.balanceOf(address(farm)), inflow - outflow, "token flow mismatch");
        assertEq(locker.balanceOf(address(treasury)), handler.ghostReturned() + farm.totalFeesToTreasury());
    }

    /// @dev Fee-eligible and pending stake always add up to the principal, so no stake is counted
    ///      twice or lost by the eligibility delay.
    function invariant_eligiblePlusPendingIsStaked() public view {
        uint256 pending;
        for (uint256 i; i < handler.actorCount(); ++i) {
            pending += farm.pendingStakeOf(handler.actors(i));
        }
        assertEq(farm.eligibleTotalStaked() + pending, farm.totalStaked(), "eligibility accounting drift");
    }

    /// @dev Emissions never exceed what was funded.
    function invariant_committedNeverExceedsFunding() public view {
        assertLe(
            farm.rewardReserve() + farm.remainingEpochRewards() + handler.ghostRewardsClaimed()
                + handler.ghostReturned(),
            handler.ghostFunded(),
            "emissions backed by something other than funding"
        );
    }
}
