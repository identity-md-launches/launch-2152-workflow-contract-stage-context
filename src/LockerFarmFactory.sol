// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {LockerFarm} from "./LockerFarm.sol";
import {ILockerFarm} from "./interfaces/ILockerFarm.sol";

/// @title LockerFarmFactory
/// @notice Registry and factory of Locker farms. The owner creates new, independently funded farms
///         for additional staking tokens at any time without touching the existing ones.
///
/// @dev The owner role of this contract is the "farm creation" role. It is two-step transferable and
///      can be renounced permanently with `renounceOwnership`, after which no farm can be created or
///      registered again. Farms created here start with `admin` as emissions manager and guardian;
///      each farm's roles are then managed and renounced on the farm itself.
contract LockerFarmFactory is Ownable2Step {
    /// @notice LOCKER, the reward token every farm emits.
    address public immutable rewardToken;
    /// @notice The LockerTreasury every farm sends its fee share to.
    address public immutable treasury;

    address[] private _farms;
    /// @notice True for every farm created or registered here.
    mapping(address farm => bool) public isFarm;
    /// @notice Farms by staking token, in creation order.
    mapping(address stakingToken => address[]) private _farmsByToken;

    event FarmCreated(address indexed farm, address indexed stakingToken, address indexed admin);
    event FarmRegistered(address indexed farm, address indexed stakingToken);

    error ZeroAddress();
    error AlreadyRegistered(address farm);
    error FarmMismatch(address farm);

    /// @param owner_ the launch owner (`$owner`)
    /// @param rewardToken_ the LaunchToken (`$token`)
    /// @param treasury_ the LockerTreasury (`$contract:LockerTreasury`)
    constructor(address owner_, address rewardToken_, address treasury_) Ownable(owner_) {
        if (rewardToken_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        rewardToken = rewardToken_;
        treasury = treasury_;
    }

    /// @notice Deploy a new farm for `stakingToken` with `admin` as its initial emissions manager and
    ///         guardian. Existing farms are untouched.
    function createFarm(address stakingToken, address admin) external onlyOwner returns (address farm) {
        if (stakingToken == address(0) || admin == address(0)) revert ZeroAddress();
        farm = address(new LockerFarm(stakingToken, rewardToken, treasury, admin));
        _add(farm, stakingToken);
        emit FarmCreated(farm, stakingToken, admin);
    }

    /// @notice List a farm deployed outside this factory (the launch deploys the LOCKER farm directly).
    ///         The farm must emit this factory's reward token and pay fees to the same Treasury.
    function registerFarm(address farm) external onlyOwner {
        if (farm == address(0)) revert ZeroAddress();
        if (isFarm[farm]) revert AlreadyRegistered(farm);
        if (ILockerFarm(farm).rewardToken() != rewardToken || ILockerFarm(farm).treasury() != treasury) {
            revert FarmMismatch(farm);
        }
        address stakingToken = ILockerFarm(farm).stakingToken();
        _add(farm, stakingToken);
        emit FarmRegistered(farm, stakingToken);
    }

    /// @notice Number of farms known to the registry.
    function farmCount() external view returns (uint256) {
        return _farms.length;
    }

    /// @notice Farm at `index` in creation order.
    function farmAt(uint256 index) external view returns (address) {
        return _farms[index];
    }

    /// @notice Every farm known to the registry.
    function allFarms() external view returns (address[] memory) {
        return _farms;
    }

    /// @notice Farms whose staking token is `stakingToken`.
    function farmsByToken(address stakingToken) external view returns (address[] memory) {
        return _farmsByToken[stakingToken];
    }

    /// @dev Once ownership is renounced nobody, not even a caller spoofing `address(0)`, passes.
    function _checkOwner() internal view override {
        address current = owner();
        if (current == address(0) || current != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
    }

    function _add(address farm, address stakingToken) private {
        isFarm[farm] = true;
        _farms.push(farm);
        _farmsByToken[stakingToken].push(farm);
    }
}
