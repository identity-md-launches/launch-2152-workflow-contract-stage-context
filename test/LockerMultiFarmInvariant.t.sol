// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockerFarm} from "../src/LockerFarm.sol";
import {LockerTreasury} from "../src/LockerTreasury.sol";
import {LockerFarmFactory} from "../src/LockerFarmFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives two farms that share one Treasury and one reward token (an IMD-like farm created by the
///      factory and the LOCKER farm, whose staked and reward tokens coincide) with several actors,
///      Treasury refills and guardian actions. Per-call properties that cannot be read back from
///      state afterwards (self-fee, exact payout, isolation, renounced roles staying renounced) are
///      recorded as violation counters checked by the invariants.
contract MultiFarmHandler is Test {
    LaunchToken public locker;
    MockERC20 public imd;
    LockerTreasury public treasury;
    LockerFarm[2] public farms;
    address public owner;
    address[] public actors;

    // Per farm ghosts, index 0 = IMD farm, 1 = LOCKER farm.
    uint256[2] public deposited;
    uint256[2] public withdrawnNet;
    uint256[2] public feesClaimed;
    uint256[2] public rewardsClaimed;
    uint256[2] public funded;
    uint256[2] public returned;
    uint256[2] public lastFeePerShare;
    uint256[2] public lastRewardPerToken;
    bool[2] public guardianRenounced;
    bool[2] public emissionsRenounced;
    uint256[2] public swept;

    uint256 public selfFeeViolations;
    uint256 public payoutViolations;
    uint256 public isolationViolations;
    uint256 public accumulatorDecreases;
    uint256 public roleRestorations;
    uint256 public feeRecipientViolations;
    uint256 public treasuryShareViolations;
    uint256 public withdrawalsWithEligibleOthers;
    uint256 public withdrawalsWithoutEligibleOthers;
    uint256 public renounceViolations;
    uint256 public emissionsRenounces;

    constructor(
        LaunchToken locker_,
        MockERC20 imd_,
        LockerTreasury treasury_,
        LockerFarm imdFarm_,
        LockerFarm lockerFarm_,
        address owner_
    ) {
        locker = locker_;
        imd = imd_;
        treasury = treasury_;
        farms[0] = imdFarm_;
        farms[1] = lockerFarm_;
        owner = owner_;
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA4E));
        actors.push(address(0xE11E));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 i) internal view returns (address) {
        return i == 0 ? address(imd) : address(locker);
    }

    /// @dev What a withdrawal of `amount` pays out: the 10% fee rounds up to the wei.
    function _net(uint256 amount) internal pure returns (uint256) {
        return amount - (amount * 1_000 + 9_999) / 10_000;
    }

    function _bal(uint256 i, address who) internal view returns (uint256) {
        return i == 0 ? imd.balanceOf(who) : locker.balanceOf(who);
    }

    /// @dev Snapshot of the farm the call does not target, to prove isolation.
    function _otherState(uint256 i) internal view returns (bytes32) {
        LockerFarm o = farms[1 - i];
        return keccak256(
            abi.encode(
                o.totalStaked(),
                o.rewardReserve(),
                o.feePerShareStored(),
                o.rewardRate(),
                o.periodFinish(),
                o.lastUpdateTime()
            )
        );
    }

    function _after(uint256 i, bytes32 otherBefore) internal {
        if (_otherState(i) != otherBefore) ++isolationViolations;
        for (uint256 k; k < 2; ++k) {
            uint256 fps = farms[k].feePerShareStored();
            uint256 rpt = farms[k].rewardPerToken();
            if (fps < lastFeePerShare[k] || rpt < lastRewardPerToken[k]) ++accumulatorDecreases;
            lastFeePerShare[k] = fps;
            lastRewardPerToken[k] = rpt;
            if (guardianRenounced[k] && (farms[k].guardian() != address(0) || farms[k].depositsPaused())) {
                ++roleRestorations;
            }
            if (
                emissionsRenounced[k]
                    && (farms[k].emissionsManager() != address(0) || farms[k].pendingEmissionsManager() != address(0))
            ) ++roleRestorations;
        }
    }

    function deposit(uint256 farmSeed, uint256 actorSeed, uint256 amount) external {
        uint256 i = farmSeed % 2;
        LockerFarm farm = farms[i];
        if (farm.depositsPaused()) return;
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 50_000_000e18);
        if (i == 0) {
            imd.mint(who, amount);
        } else {
            vm.prank(owner);
            locker.transfer(who, amount);
        }
        bytes32 other = _otherState(i);
        vm.startPrank(who);
        MockERC20(_token(i)).approve(address(farm), amount);
        farm.deposit(amount);
        vm.stopPrank();
        deposited[i] += amount;
        _after(i, other);
    }

    function withdraw(uint256 farmSeed, uint256 actorSeed, uint256 amount) external {
        uint256 i = farmSeed % 2;
        LockerFarm farm = farms[i];
        address who = _actor(actorSeed);
        uint256 bal = farm.balanceOf(who);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 pendingBefore = farm.pendingFees(who);
        uint256 before = _bal(i, who);
        Split memory split = _snapshot(i, who);
        bytes32 other = _otherState(i);
        vm.prank(who);
        farm.withdraw(amount);
        uint256 got = _bal(i, who) - before;
        withdrawnNet[i] += got;
        if (got != _net(amount)) ++payoutViolations;
        // The withdrawer's claimable fees must not grow from their own withdrawal.
        if (farm.pendingFees(who) > pendingBefore) ++selfFeeViolations;
        _checkSplit(i, who, amount, split);
        _after(i, other);
    }

    struct Split {
        uint256 treasuryBefore;
        uint256 othersEligible;
        uint256[] elig;
        uint256[] fees;
    }

    /// @dev Every other depositor's eligible stake and claimable fees before a withdrawal.
    function _snapshot(uint256 i, address who) internal view returns (Split memory split) {
        LockerFarm farm = farms[i];
        uint256 n = actors.length;
        split.treasuryBefore = _bal(i, address(treasury));
        split.elig = new uint256[](n);
        split.fees = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            if (actors[k] == who) continue;
            split.elig[k] = farm.eligibleStakeOf(actors[k]);
            split.fees[k] = farm.pendingFees(actors[k]);
            split.othersEligible += split.elig[k];
        }
    }

    /// @dev 9% goes to the other eligible stake in proportion, or all 10% to the Treasury if none.
    function _checkSplit(uint256 i, address who, uint256 amount, Split memory split) internal {
        LockerFarm farm = farms[i];
        uint256 fee = amount - _net(amount);
        uint256 redistributed = split.othersEligible > 0 ? amount * 900 / 10_000 : 0;
        if (_bal(i, address(treasury)) - split.treasuryBefore != fee - redistributed) ++treasuryShareViolations;
        if (split.othersEligible > 0) ++withdrawalsWithEligibleOthers;
        else ++withdrawalsWithoutEligibleOthers;
        uint256 gained;
        for (uint256 k; k < actors.length; ++k) {
            if (actors[k] == who) continue;
            uint256 inc = farm.pendingFees(actors[k]) - split.fees[k];
            gained += inc;
            if (split.elig[k] == 0 && inc != 0) ++feeRecipientViolations; // pending stake earned a fee
            if (split.elig[k] > 0 && inc > redistributed * split.elig[k] / split.othersEligible + 1) {
                ++feeRecipientViolations;
            }
        }
        if (gained > redistributed) ++feeRecipientViolations;
    }

    function exit(uint256 farmSeed, uint256 actorSeed) external {
        uint256 i = farmSeed % 2;
        LockerFarm farm = farms[i];
        address who = _actor(actorSeed);
        uint256 bal = farm.balanceOf(who);
        uint256 fees = farm.pendingFees(who);
        uint256 reward = farm.earned(who);
        uint256 stakeBefore = _bal(i, who);
        uint256 lockerBefore = locker.balanceOf(who);
        bytes32 other = _otherState(i);
        vm.prank(who);
        farm.exit();
        uint256 net = _net(bal);
        if (i == 0) {
            withdrawnNet[0] += net;
            feesClaimed[0] += imd.balanceOf(who) - stakeBefore - net;
            rewardsClaimed[0] += locker.balanceOf(who) - lockerBefore;
            if (imd.balanceOf(who) - stakeBefore != net + fees) ++payoutViolations;
        } else {
            withdrawnNet[1] += net;
            feesClaimed[1] += fees;
            rewardsClaimed[1] += reward;
            if (locker.balanceOf(who) - lockerBefore != net + fees + reward) ++payoutViolations;
        }
        if (farm.balanceOf(who) != 0 || farm.pendingFees(who) != 0 || farm.earned(who) != 0) ++payoutViolations;
        _after(i, other);
    }

    function claimFees(uint256 farmSeed, uint256 actorSeed) external {
        uint256 i = farmSeed % 2;
        address who = _actor(actorSeed);
        uint256 expected = farms[i].pendingFees(who);
        uint256 before = _bal(i, who);
        bytes32 other = _otherState(i);
        vm.prank(who);
        farms[i].claimFees();
        uint256 got = _bal(i, who) - before;
        if (got != expected) ++payoutViolations;
        feesClaimed[i] += got;
        _after(i, other);
    }

    function claimRewards(uint256 farmSeed, uint256 actorSeed) external {
        uint256 i = farmSeed % 2;
        address who = _actor(actorSeed);
        uint256 expected = farms[i].earned(who);
        uint256 before = locker.balanceOf(who);
        bytes32 other = _otherState(i);
        vm.prank(who);
        farms[i].claimRewards();
        uint256 got = locker.balanceOf(who) - before;
        if (got != expected) ++payoutViolations;
        rewardsClaimed[i] += got;
        _after(i, other);
    }

    /// @dev Owner refills a farm through the Treasury, as the brief describes for buybacks.
    function treasuryFund(uint256 farmSeed, uint256 amount) external {
        uint256 i = farmSeed % 2;
        amount = bound(amount, 1, 2_000_000e18);
        if (emissionsRenounced[i]) {
            // Funding a farm whose emissions are renounced would strand LOCKER: it must be refused,
            // whoever sends it. A stranger tries directly; the tokens stay with them on refusal.
            address who = _actor(amount);
            vm.prank(owner);
            locker.transfer(who, amount);
            vm.startPrank(who);
            locker.approve(address(farms[i]), amount);
            try farms[i].fundRewards(amount) {
                ++renounceViolations;
            } catch {}
            locker.approve(address(farms[i]), 0);
            vm.stopPrank();
            return;
        }
        vm.startPrank(owner);
        locker.transfer(address(treasury), amount);
        bytes32 other = _otherState(i);
        uint256 rateBefore = farms[i].rewardRate();
        treasury.fundFarm(address(farms[i]), amount);
        vm.stopPrank();
        if (farms[i].rewardRate() != rateBefore) ++payoutViolations; // funding must not raise emissions
        funded[i] += amount;
        _after(i, other);
    }

    function startEpoch(uint256 farmSeed, uint256 amount) external {
        uint256 i = farmSeed % 2;
        if (emissionsRenounced[i]) return _tryManage(i, amount);
        uint256 reserve = farms[i].rewardReserve();
        if (reserve < 30 days) return;
        amount = bound(amount, 30 days, reserve);
        bytes32 other = _otherState(i);
        vm.prank(owner);
        farms[i].startEpoch(amount);
        _after(i, other);
    }

    function boost(uint256 farmSeed, uint256 amount) external {
        uint256 i = farmSeed % 2;
        if (emissionsRenounced[i]) return _tryManage(i, amount);
        if (block.timestamp >= farms[i].periodFinish()) return;
        uint256 reserve = farms[i].rewardReserve();
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        bytes32 other = _otherState(i);
        vm.prank(owner);
        farms[i].boostEmissions(amount);
        _after(i, other);
    }

    function setRate(uint256 farmSeed, uint256 rate) external {
        uint256 i = farmSeed % 2;
        if (emissionsRenounced[i]) return _tryManage(i, rate);
        LockerFarm farm = farms[i];
        if (block.timestamp >= farm.periodFinish()) return;
        uint256 remaining = farm.periodFinish() - block.timestamp;
        uint256 available = farm.rewardReserve() + farm.rewardRate() * remaining;
        rate = bound(rate, 0, available / remaining);
        bytes32 other = _otherState(i);
        vm.prank(owner);
        farm.setRewardRate(rate);
        _after(i, other);
    }

    function returnUncommitted(uint256 farmSeed, uint256 amount) external {
        uint256 i = farmSeed % 2;
        uint256 reserve = farms[i].rewardReserve();
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        bytes32 other = _otherState(i);
        // Once emissions are renounced the return is permissionless; any actor may push it.
        vm.prank(emissionsRenounced[i] ? _actor(amount) : owner);
        farms[i].returnUncommittedRewards(amount);
        returned[i] += amount;
        _after(i, other);
    }

    /// @dev After the emissions manager renounced, the former holder must not be able to run any
    ///      emissions function.
    function _tryManage(uint256 i, uint256 amount) internal {
        LockerFarm farm = farms[i];
        uint256 reserve = farm.rewardReserve();
        vm.startPrank(owner);
        try farm.startEpoch(reserve) {
            ++roleRestorations;
        } catch {}
        try farm.boostEmissions(bound(amount, 1, reserve + 1)) {
            ++roleRestorations;
        } catch {}
        try farm.setRewardRate(0) {
            ++roleRestorations;
        } catch {}
        vm.stopPrank();
        _after(i, _otherState(i));
    }

    struct RenounceSnap {
        uint256 reserve;
        uint256 treasuryLocker;
        uint256 rate;
        uint256 finish;
        uint256 remaining;
        uint256 totalStaked;
        uint256[] earned;
        uint256[] fees;
    }

    /// @dev Occasionally renounces a farm's emissions manager at an arbitrary point (running epoch,
    ///      no stakers, leftover reserve, ...). The renounce must sweep exactly the uncommitted
    ///      reserve (including emissions recycled over a no-staker span) to the Treasury and leave
    ///      the running epoch, principal, fees and accrued rewards untouched.
    function renounceEmissions(uint256 farmSeed, uint256 dice) external {
        uint256 i = farmSeed % 2;
        if (emissionsRenounced[i] || dice % 4 != 0) return;
        LockerFarm farm = farms[i];
        RenounceSnap memory s;
        s.reserve = farm.rewardReserve();
        s.treasuryLocker = locker.balanceOf(address(treasury));
        s.rate = farm.rewardRate();
        s.finish = farm.periodFinish();
        s.remaining = farm.remainingEpochRewards();
        s.totalStaked = farm.totalStaked();
        uint256 n = actors.length;
        s.earned = new uint256[](n);
        s.fees = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            s.earned[k] = farm.earned(actors[k]);
            s.fees[k] = farm.pendingFees(actors[k]);
        }
        // Emissions since the last update that nobody was staked for return to the reserve first.
        uint256 recycled = s.totalStaked == 0 ? (farm.lastTimeRewardApplicable() - farm.lastUpdateTime()) * s.rate : 0;
        bytes32 other = _otherState(i);

        vm.prank(owner);
        farm.renounceEmissionsManager();
        emissionsRenounced[i] = true;
        ++emissionsRenounces;

        uint256 got = locker.balanceOf(address(treasury)) - s.treasuryLocker;
        swept[i] += got;
        returned[i] += got;
        if (got != s.reserve + recycled) ++renounceViolations;
        if (farm.rewardReserve() != 0) ++renounceViolations;
        if (farm.rewardRate() != s.rate || farm.periodFinish() != s.finish) ++renounceViolations;
        if (farm.remainingEpochRewards() != s.remaining || farm.totalStaked() != s.totalStaked) {
            ++renounceViolations;
        }
        for (uint256 k; k < n; ++k) {
            if (farm.earned(actors[k]) != s.earned[k] || farm.pendingFees(actors[k]) != s.fees[k]) {
                ++renounceViolations;
            }
        }
        if (farm.emissionsManager() != address(0) || farm.pendingEmissionsManager() != address(0)) {
            ++renounceViolations;
        }
        _after(i, other);
    }

    function togglePause(uint256 farmSeed) external {
        uint256 i = farmSeed % 2;
        if (guardianRenounced[i]) return;
        bool paused = farms[i].depositsPaused();
        vm.prank(owner);
        if (paused) farms[i].unpauseDeposits();
        else farms[i].pauseDeposits();
        _after(i, _otherState(i));
    }

    /// @dev Rarely renounces a farm's guardian, then lets anyone try to take it back.
    function renounceGuardian(uint256 farmSeed, uint256 dice) external {
        uint256 i = farmSeed % 2;
        if (guardianRenounced[i] || dice % 8 != 0) return;
        vm.prank(owner);
        farms[i].renounceGuardian();
        guardianRenounced[i] = true;
        _after(i, _otherState(i));
    }

    function tryRestoreGuardian(uint256 farmSeed, uint256 callerSeed) external {
        uint256 i = farmSeed % 2;
        address caller = callerSeed % 3 == 0 ? owner : callerSeed % 3 == 1 ? address(0) : _actor(callerSeed);
        if (emissionsRenounced[i]) {
            vm.prank(caller);
            try farms[i].setEmissionsManager(caller) {
                ++roleRestorations;
            } catch {}
            vm.prank(caller);
            try farms[i].acceptEmissionsManager() {
                ++roleRestorations;
            } catch {}
        }
        vm.prank(caller);
        try farms[i].setGuardian(caller) {
            if (guardianRenounced[i]) ++roleRestorations;
        } catch {}
        vm.prank(caller);
        try farms[i].pauseDeposits() {
            if (guardianRenounced[i]) ++roleRestorations;
            // A legitimate pause by the guardian: undo it so deposits keep flowing.
            vm.prank(caller);
            farms[i].unpauseDeposits();
        } catch {}
        _after(i, _otherState(i));
    }

    /// @dev Mostly short hops, so stake is often caught inside its fee-eligibility delay.
    function warp(uint256 secs) external {
        vm.warp(block.timestamp + (secs % 4 == 0 ? bound(secs, 1, 12 days) : bound(secs, 1, 30 hours)));
        _after(0, _otherState(0));
    }
}

contract LockerMultiFarmInvariantTest is Test {
    address internal constant OWNER = address(0xDEA11b3A70b77134424d436f6eb455f1Abbd4449);

    LaunchToken internal locker;
    MockERC20 internal imd;
    LockerTreasury internal treasury;
    LockerFarmFactory internal factory;
    LockerFarm internal imdFarm;
    LockerFarm internal lockerFarm;
    MultiFarmHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(OWNER);
        locker = new LaunchToken();
        imd = new MockERC20("IMD", "IMD");
        treasury = new LockerTreasury(OWNER, address(locker));
        factory = new LockerFarmFactory(OWNER, address(locker), address(treasury));
        lockerFarm = new LockerFarm(address(locker), address(locker), address(treasury), OWNER);
        vm.prank(OWNER);
        imdFarm = LockerFarm(factory.createFarm(address(imd), OWNER));
        handler = new MultiFarmHandler(locker, imd, treasury, imdFarm, lockerFarm, OWNER);
        targetContract(address(handler));
    }

    function _farm(uint256 i) internal view returns (LockerFarm) {
        return i == 0 ? imdFarm : lockerFarm;
    }

    function _sums(LockerFarm farm) internal view returns (uint256 stakes, uint256 fees, uint256 earned) {
        for (uint256 a; a < handler.actorCount(); ++a) {
            address who = handler.actors(a);
            stakes += farm.balanceOf(who);
            fees += farm.pendingFees(who);
            earned += farm.earned(who);
        }
    }

    /// @dev Each farm can pay every principal, fee reward, accrued reward, reserve and unemitted epoch.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_eachFarmIsSolvent() public view {
        (uint256 s0, uint256 f0, uint256 e0) = _sums(imdFarm);
        assertEq(s0, imdFarm.totalStaked(), "IMD principal drift");
        assertGe(imd.balanceOf(address(imdFarm)), s0 + f0, "IMD farm cannot pay principal and fees");
        assertGe(
            locker.balanceOf(address(imdFarm)),
            e0 + imdFarm.rewardReserve() + imdFarm.remainingEpochRewards(),
            "IMD farm cannot pay LOCKER rewards"
        );

        (uint256 s1, uint256 f1, uint256 e1) = _sums(lockerFarm);
        assertEq(s1, lockerFarm.totalStaked(), "LOCKER principal drift");
        assertGe(
            locker.balanceOf(address(lockerFarm)),
            s1 + f1 + e1 + lockerFarm.rewardReserve() + lockerFarm.remainingEpochRewards(),
            "LOCKER farm insolvent"
        );
    }

    /// @dev Fees paid or owed never exceed fees redistributed; rewards paid, owed, reserved,
    ///      returned or still to emit never exceed what was funded.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_nothingPromisedBeyondItsSource() public view {
        for (uint256 i; i < 2; ++i) {
            LockerFarm farm = _farm(i);
            (, uint256 fees, uint256 earned) = _sums(farm);
            assertLe(handler.feesClaimed(i) + fees, farm.totalFeesRedistributed(), "fees over-promised");
            assertLe(
                handler.rewardsClaimed(i) + earned + farm.rewardReserve() + farm.remainingEpochRewards()
                    + handler.returned(i),
                handler.funded(i),
                "emissions exceed funding"
            );
        }
    }

    /// @dev Token flows balance exactly, and the Treasury holds only its fee share and returned reserve.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_tokenConservation() public view {
        assertEq(
            imd.balanceOf(address(imdFarm)),
            handler.deposited(0) - handler.withdrawnNet(0) - handler.feesClaimed(0) - imdFarm.totalFeesToTreasury(),
            "IMD flow mismatch"
        );
        assertEq(imd.balanceOf(address(treasury)), imdFarm.totalFeesToTreasury(), "Treasury IMD mismatch");
        assertEq(
            locker.balanceOf(address(imdFarm)),
            handler.funded(0) - handler.rewardsClaimed(0) - handler.returned(0),
            "IMD farm LOCKER mismatch"
        );
        assertEq(
            locker.balanceOf(address(lockerFarm)),
            handler.deposited(1) + handler.funded(1) - handler.withdrawnNet(1) - handler.feesClaimed(1)
                - handler.rewardsClaimed(1) - handler.returned(1) - lockerFarm.totalFeesToTreasury(),
            "LOCKER farm flow mismatch"
        );
        assertEq(
            locker.balanceOf(address(treasury)),
            handler.returned(0) + handler.returned(1) + lockerFarm.totalFeesToTreasury(),
            "Treasury LOCKER mismatch"
        );
        assertEq(locker.totalSupply(), 1_000_000_000 ether, "supply changed");
    }

    /// @dev Per-call properties recorded by the handler.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_perCallProperties() public view {
        assertEq(handler.selfFeeViolations(), 0, "withdrawer earned from own fee");
        assertEq(handler.payoutViolations(), 0, "payout differed from the promised amount");
        assertEq(handler.isolationViolations(), 0, "an action on one farm changed the other");
        assertEq(handler.accumulatorDecreases(), 0, "an accumulator went backwards");
        assertEq(handler.roleRestorations(), 0, "a renounced guardian role was used or restored");
        assertEq(handler.feeRecipientViolations(), 0, "a fee reached pending stake or exceeded a pro-rata share");
        assertEq(handler.treasuryShareViolations(), 0, "Treasury received the wrong share of a fee");
        assertEq(handler.renounceViolations(), 0, "emissions renounce swept the wrong amount or touched owed value");
    }

    /// @dev Per-account eligibility adds up to the global figures the fee split uses.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_eligibilityAccounting() public view {
        for (uint256 i; i < 2; ++i) {
            LockerFarm farm = _farm(i);
            uint256 eligible;
            for (uint256 a; a < handler.actorCount(); ++a) {
                address who = handler.actors(a);
                uint256 pending = farm.pendingStakeOf(who);
                assertLe(pending, farm.balanceOf(who), "pending stake above balance");
                eligible += farm.eligibleStakeOf(who);
            }
            assertEq(eligible, farm.eligibleTotalStaked(), "eligible stake drift");
            assertLe(farm.eligibleTotalStaked(), farm.totalStaked());
        }
    }

    /// @dev Roles nobody renounced stay with the owner, renounced ones stay empty; the factory
    ///      registry is untouched by farm use.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_rolesAndRegistry() public view {
        for (uint256 i; i < 2; ++i) {
            assertEq(_farm(i).emissionsManager(), handler.emissionsRenounced(i) ? address(0) : OWNER);
        }
        assertEq(treasury.owner(), OWNER);
        assertEq(factory.owner(), OWNER);
        assertEq(factory.farmCount(), 1);
        assertTrue(factory.isFarm(address(imdFarm)));
    }
}
