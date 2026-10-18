// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LockerFarm} from "../../src/LockerFarm.sol";

/// @dev An ERC-20 with a transfer hook, modelling ERC-777-style callbacks: whenever tokens reach
///      `hookTarget`, it is called and may try to re-enter the farm.
contract ReenteringToken is ERC20 {
    address public hookTarget;

    constructor() ERC20("Hooked", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHookTarget(address target) external {
        hookTarget = target;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == hookTarget && to != address(0)) {
            IReentrancyHook(to).onTokenReceived(from, value);
        }
    }
}

interface IReentrancyHook {
    function onTokenReceived(address from, uint256 value) external;
}

/// @dev Attacker that deposits into a farm and, when paid by it, tries to call back in.
contract ReentrancyAttacker is IReentrancyHook {
    LockerFarm public immutable farm;
    ReenteringToken public immutable token;
    bytes public reenterCall;
    bool public reenterSucceeded;
    bytes public reenterError;
    uint256 public hookCalls;

    constructor(LockerFarm farm_, ReenteringToken token_) {
        farm = farm_;
        token = token_;
    }

    function depositToFarm(uint256 amount) external {
        token.approve(address(farm), amount);
        farm.deposit(amount);
    }

    function attack(bytes calldata call, uint256 withdrawAmount) external {
        reenterCall = call;
        farm.withdraw(withdrawAmount);
    }

    function claimFeesAttack(bytes calldata call) external {
        reenterCall = call;
        farm.claimFees();
    }

    function onTokenReceived(address from, uint256) external override {
        if (from != address(farm) || reenterCall.length == 0) return;
        hookCalls++;
        (bool ok, bytes memory err) = address(farm).call(reenterCall);
        reenterSucceeded = ok;
        reenterError = err;
    }
}
