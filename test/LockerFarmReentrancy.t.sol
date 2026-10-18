// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {LockerTreasury} from "../src/LockerTreasury.sol";
import {ReenteringToken, ReentrancyAttacker} from "./mocks/ReenteringToken.sol";

/// @notice A staking token with transfer callbacks cannot re-enter the farm mid-withdrawal or mid-claim.
contract LockerFarmReentrancyTest is Test {
    address internal constant OWNER = address(0xDEA11b3A70b77134424d436f6eb455f1Abbd4449);
    address internal constant VICTIM = address(0x1111);

    LaunchToken internal locker;
    ReenteringToken internal hooked;
    LockerTreasury internal treasury;
    LockerFarm internal farm;
    ReentrancyAttacker internal attacker;

    function setUp() public {
        vm.warp(1_700_000_000);
        locker = new LaunchToken();
        hooked = new ReenteringToken();
        treasury = new LockerTreasury(OWNER, address(locker));
        farm = new LockerFarm(address(hooked), address(locker), address(treasury), OWNER);
        attacker = new ReentrancyAttacker(farm, hooked);
        hooked.setHookTarget(address(attacker));

        hooked.mint(VICTIM, 1_000e18);
        vm.startPrank(VICTIM);
        hooked.approve(address(farm), type(uint256).max);
        farm.deposit(1_000e18);
        vm.stopPrank();

        hooked.mint(address(attacker), 1_000e18);
        attacker.depositToFarm(1_000e18);
        // Past the fee-eligibility delay, so both stakes share fees.
        vm.warp(block.timestamp + 2 days);
    }

    function test_reenteringWithdrawIsBlocked() public {
        attacker.attack(abi.encodeCall(LockerFarm.withdraw, (500e18)), 500e18);
        assertEq(attacker.hookCalls(), 1, "hook ran");
        assertFalse(attacker.reenterSucceeded(), "re-entrant withdraw rejected");
        assertEq(bytes4(attacker.reenterError()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        // Exactly one withdrawal happened.
        assertEq(farm.balanceOf(address(attacker)), 500e18);
        assertEq(hooked.balanceOf(address(attacker)), 450e18);
        assertEq(farm.pendingFees(VICTIM), 45e18);
        assertEq(hooked.balanceOf(address(treasury)), 5e18);
        assertEq(hooked.balanceOf(address(farm)), farm.totalStaked() + farm.pendingFees(VICTIM));
    }

    function test_reenteringClaimFeesIsBlocked() public {
        // Victim withdraws so the attacker has fees owed, then attacker claims and tries to claim again inside.
        vm.prank(VICTIM);
        farm.withdraw(1_000e18);
        assertEq(farm.pendingFees(address(attacker)), 90e18);
        attacker.claimFeesAttack(abi.encodeCall(LockerFarm.claimFees, ()));
        assertFalse(attacker.reenterSucceeded());
        assertEq(hooked.balanceOf(address(attacker)), 90e18, "paid once");
        assertEq(farm.pendingFees(address(attacker)), 0);
    }

    function test_reenteringExitIsBlocked() public {
        attacker.attack(abi.encodeCall(LockerFarm.exit, ()), 1_000e18);
        assertFalse(attacker.reenterSucceeded());
        assertEq(farm.balanceOf(address(attacker)), 0);
        assertEq(hooked.balanceOf(address(attacker)), 900e18);
    }

    function test_reenteringDepositIsBlocked() public {
        attacker.attack(abi.encodeCall(LockerFarm.deposit, (1e18)), 100e18);
        assertFalse(attacker.reenterSucceeded());
        assertEq(farm.balanceOf(address(attacker)), 900e18);
    }
}
