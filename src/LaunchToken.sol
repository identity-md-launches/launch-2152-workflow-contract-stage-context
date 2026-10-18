// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken (Locker, LOCKER)
/// @notice The fixed-supply launch token of the Locker farming platform.
/// @dev Exactly 1,000,000,000 LOCKER (10^27 minor units, 18 decimals) is minted once to the
///      deployer, which is the launch factory. There is no owner, no mint, no pause, no blocklist,
///      no transfer fee and no upgrade path. The factory splits the supply according to the launch
///      form (10% swarm, 30% pool, 60% requester wallet); nothing in this repository changes that.
contract LaunchToken is ERC20 {
    /// @notice Total and only supply: one billion tokens at 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Locker", "LOCKER") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
