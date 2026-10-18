// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The surface of a Locker farm that other Locker contracts rely on.
interface ILockerFarm {
    function stakingToken() external view returns (address);
    function rewardToken() external view returns (address);
    function treasury() external view returns (address);
    function fundRewards(uint256 amount) external;
}
