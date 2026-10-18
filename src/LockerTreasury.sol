// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ILockerFarm} from "./interfaces/ILockerFarm.sol";

/// @title LockerTreasury
/// @notice Holds the protocol's LOCKER (the requester transfers 50% of the supply here after launch),
///         receives the 1% Treasury share of every withdrawal fee in the staked tokens, and refills
///         individual farm reward balances on the owner's instruction.
///
/// @dev The Treasury has no privilege over any farm: it only holds its own balances and can call the
///      permissionless `fundRewards` on a farm. It can never reach user deposits or accrued rewards.
///      Ownership is two-step and cannot be renounced, so Treasury control is retained even after the
///      farm roles are renounced. Buybacks and the 80/20 Treasury/Team split of LP fees are manual:
///      the owner withdraws funds with `withdrawToken` / `withdrawETH` and trades off-chain or on a
///      DEX from their own wallet. Nothing here trades automatically.
contract LockerTreasury is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice LOCKER, the launch token.
    IERC20 public immutable lockerToken;

    event FarmFunded(address indexed farm, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event ETHReceived(address indexed from, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ETHTransferFailed();
    error FarmRewardTokenMismatch(address farm, address rewardToken);
    error OwnershipNotRenounceable();

    /// @param owner_ the launch owner (resolved from the launch context as `$owner`)
    /// @param lockerToken_ the LaunchToken address (`$token`)
    constructor(address owner_, address lockerToken_) Ownable(owner_) {
        if (lockerToken_ == address(0)) revert ZeroAddress();
        lockerToken = IERC20(lockerToken_);
    }

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    /// @notice Move `amount` LOCKER from the Treasury into `farm`'s reward reserve. Emissions on the
    ///         farm do not change; its emissions manager commits the reserve separately.
    function fundFarm(address farm, uint256 amount) external onlyOwner {
        if (farm == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        address farmReward = ILockerFarm(farm).rewardToken();
        if (farmReward != address(lockerToken)) revert FarmRewardTokenMismatch(farm, farmReward);
        lockerToken.forceApprove(farm, amount);
        ILockerFarm(farm).fundRewards(amount);
        lockerToken.forceApprove(farm, 0);
        emit FarmFunded(farm, amount);
    }

    /// @notice Withdraw any ERC-20 the Treasury holds (LOCKER for buybacks/refills, collected fee
    ///         tokens for the manual Treasury/Team split).
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokenWithdrawn(token, to, amount);
    }

    /// @notice Withdraw ETH the Treasury holds.
    function withdrawETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
        emit ETHWithdrawn(to, amount);
    }

    /// @notice Treasury control is retained forever: renouncing would strand every balance here.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipNotRenounceable();
    }
}
