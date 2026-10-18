// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LockerFarm
/// @notice One isolated farming pool: users stake one ERC-20 (`stakingToken`) and earn LOCKER
///         (`rewardToken`) by stake and time, plus a share of the withdrawal fees other depositors
///         pay in the staked token.
///
/// @dev Architecture
///      - LOCKER emissions follow the Synthetix `StakingRewards` model (reward-per-token
///        accumulator, fixed-rate epochs). Each farm has its own reward balance and its own 30-day
///        schedule; funding a farm never changes its emission rate by itself. The emissions manager
///        commits funded LOCKER to a schedule with `startEpoch`, `boostEmissions` or `setRewardRate`,
///        and each of those checks that the reward reserve covers everything it commits, so emissions
///        can never be backed by user principal, by accrued LOCKER rewards or by accrued fee rewards.
///      - Withdrawal fees follow a MasterChef-style fee-per-share accumulator in the staked token.
///        A withdrawal of `amount` principal pays a 10% fee: 9% is distributed proportionally among
///        the *other* depositors of this farm (the withdrawer's remaining stake is excluded even on a
///        partial withdrawal) and 1% goes to the Treasury. With no other depositor, all 10% goes to
///        the Treasury. Per-share rounding dust (a few wei) stays in the farm, which keeps it
///        solvent. Fee rewards are claimable at once, with no further fee, and remain claimable
///        after a full withdrawal.
///      - For the LOCKER farm the staked token and the reward token are the same ERC-20. Principal,
///        fee rewards, the uncommitted reward reserve and committed emissions are tracked as separate
///        numbers, so the contract never pays one out of another.
///
///      Roles (each renounceable individually and permanently, none recoverable once renounced):
///      - `emissionsManager`: starts epochs, boosts or re-rates the running epoch and may return
///        *uncommitted* reward reserve to the Treasury. Cannot touch principal or accrued rewards.
///      - `guardian`: emergency control; may pause and unpause deposits. Withdrawals and claims can
///        never be paused.
///      The fee recipient `treasury` is immutable and has no power over this contract.
contract LockerFarm is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ----------------------------------------------------------------------------------------
    // Constants
    // ----------------------------------------------------------------------------------------

    /// @notice Length of every farming epoch.
    uint256 public constant EPOCH_DURATION = 30 days;
    /// @notice Total withdrawal fee on withdrawn principal, in basis points (10%).
    uint256 public constant WITHDRAWAL_FEE_BPS = 1_000;
    /// @notice Part of the fee redistributed to the other depositors, in basis points (9%).
    uint256 public constant REDISTRIBUTED_FEE_BPS = 900;
    /// @notice Part of the fee sent to the Treasury, in basis points (1%).
    uint256 public constant TREASURY_FEE_BPS = 100;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Fixed-point scale of the two per-share accumulators.
    uint256 public constant PRECISION = 1e18;

    // ----------------------------------------------------------------------------------------
    // Immutable configuration
    // ----------------------------------------------------------------------------------------

    /// @notice Token users deposit into this farm.
    IERC20 public immutable stakingToken;
    /// @notice Token emitted as farming rewards (LOCKER).
    IERC20 public immutable rewardToken;
    /// @notice Recipient of the Treasury share of withdrawal fees and of returned reward reserve.
    address public immutable treasury;

    // ----------------------------------------------------------------------------------------
    // Roles
    // ----------------------------------------------------------------------------------------

    /// @notice Controls emission schedules. `address(0)` once renounced.
    address public emissionsManager;
    /// @notice Emergency role that can pause deposits. `address(0)` once renounced.
    address public guardian;
    /// @notice True while deposits are paused by the guardian.
    bool public depositsPaused;

    // ----------------------------------------------------------------------------------------
    // Principal
    // ----------------------------------------------------------------------------------------

    /// @notice Sum of all user principal held by this farm.
    uint256 public totalStaked;
    /// @notice Principal of each depositor.
    mapping(address account => uint256) public balanceOf;

    // ----------------------------------------------------------------------------------------
    // LOCKER emissions (Synthetix StakingRewards accounting)
    // ----------------------------------------------------------------------------------------

    /// @notice Timestamp at which the current epoch stops emitting.
    uint256 public periodFinish;
    /// @notice LOCKER emitted per second during the current epoch.
    uint256 public rewardRate;
    /// @notice Last time the reward accumulator was brought up to date.
    uint256 public lastUpdateTime;
    /// @notice Cumulative LOCKER per staked unit, scaled by `PRECISION`.
    uint256 public rewardPerTokenStored;
    /// @notice LOCKER funded to this farm but not yet committed to any epoch.
    uint256 public rewardReserve;
    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    // ----------------------------------------------------------------------------------------
    // Withdrawal-fee redistribution (staked token)
    // ----------------------------------------------------------------------------------------

    /// @notice Cumulative redistributed fees per staked unit, scaled by `PRECISION`.
    uint256 public feePerShareStored;
    /// @notice Lifetime amount of fees redistributed to depositors (for APR history).
    uint256 public totalFeesRedistributed;
    /// @notice Lifetime amount of fees sent to the Treasury.
    uint256 public totalFeesToTreasury;
    mapping(address account => uint256) public userFeePerSharePaid;
    mapping(address account => uint256) public feesOwed;

    // ----------------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------------

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount, uint256 payout, uint256 redistributed, uint256 toTreasury);
    event FeesClaimed(address indexed account, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rewardReserve);
    event EpochStarted(uint256 committed, uint256 rewardRate, uint256 periodFinish);
    event EmissionsBoosted(uint256 added, uint256 rewardRate, uint256 periodFinish);
    event RewardRateSet(uint256 rewardRate, uint256 periodFinish);
    event UncommittedRewardsReturned(address indexed to, uint256 amount);
    event EmissionsManagerTransferred(address indexed previousManager, address indexed newManager);
    event EmissionsManagerRenounced(address indexed previousManager);
    event GuardianTransferred(address indexed previousGuardian, address indexed newGuardian);
    event GuardianRenounced(address indexed previousGuardian);
    event DepositsPaused(address indexed by);
    event DepositsUnpaused(address indexed by);
    event TokenRecovered(address indexed token, uint256 amount);

    // ----------------------------------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);
    error NotEmissionsManager();
    error NotGuardian();
    error DepositsArePaused();
    error NoActiveEpoch();
    error InsufficientRewardReserve(uint256 requested, uint256 available);
    error RewardRateTooLow();
    error ProtectedToken();
    error NothingReceived();

    // ----------------------------------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------------------------------

    /// @param stakingToken_ token deposited by users
    /// @param rewardToken_ LOCKER, the launch token
    /// @param treasury_ the LockerTreasury contract
    /// @param admin_ initial holder of both the emissions-manager and guardian roles (the owner)
    constructor(address stakingToken_, address rewardToken_, address treasury_, address admin_) {
        if (
            stakingToken_ == address(0) || rewardToken_ == address(0) || treasury_ == address(0) || admin_ == address(0)
        ) {
            revert ZeroAddress();
        }
        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
        treasury = treasury_;
        emissionsManager = admin_;
        guardian = admin_;
        emit EmissionsManagerTransferred(address(0), admin_);
        emit GuardianTransferred(address(0), admin_);
    }

    // ----------------------------------------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------------------------------------

    modifier onlyEmissionsManager() {
        if (msg.sender != emissionsManager || msg.sender == address(0)) revert NotEmissionsManager();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian || msg.sender == address(0)) revert NotGuardian();
        _;
    }

    // ----------------------------------------------------------------------------------------
    // User actions
    // ----------------------------------------------------------------------------------------

    /// @notice Stake `amount` of the staking token. No deposit fee.
    function deposit(uint256 amount) external nonReentrant {
        if (depositsPaused) revert DepositsArePaused();
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);

        uint256 before = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();

        balanceOf[msg.sender] += received;
        totalStaked += received;
        emit Deposited(msg.sender, received);
    }

    /// @notice Withdraw `amount` of principal, paying the 10% withdrawal fee.
    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(msg.sender, amount);
    }

    /// @notice Claim accrued withdrawal-fee rewards in the staking token. Works after a full withdrawal.
    function claimFees() external nonReentrant {
        _settle(msg.sender);
        _claimFees(msg.sender);
    }

    /// @notice Claim accrued LOCKER farming rewards.
    function claimRewards() external nonReentrant {
        _settle(msg.sender);
        _claimRewards(msg.sender);
    }

    /// @notice Withdraw the whole principal and claim both reward kinds in one call.
    function exit() external nonReentrant {
        uint256 bal = balanceOf[msg.sender];
        if (bal > 0) {
            _withdraw(msg.sender, bal);
        } else {
            _settle(msg.sender);
        }
        _claimFees(msg.sender);
        _claimRewards(msg.sender);
    }

    // ----------------------------------------------------------------------------------------
    // Reward funding and schedules
    // ----------------------------------------------------------------------------------------

    /// @notice Add LOCKER to this farm's reward reserve. Anyone may fund. Emissions do not change
    ///         until the emissions manager commits the reserve to a schedule.
    function fundRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();
        rewardReserve += received;
        emit RewardsFunded(msg.sender, received, rewardReserve);
    }

    /// @notice Start a new 30-day epoch committing `amount` from the reserve. Whatever the current
    ///         epoch had not yet emitted rolls into the new one.
    function startEpoch(uint256 amount) external onlyEmissionsManager {
        _updateGlobalRewards();
        if (amount > rewardReserve) revert InsufficientRewardReserve(amount, rewardReserve);

        uint256 total = amount + _leftover();
        uint256 rate = total / EPOCH_DURATION;
        if (rate == 0) revert RewardRateTooLow();
        uint256 committed = rate * EPOCH_DURATION;

        rewardReserve = rewardReserve - amount + (total - committed);
        rewardRate = rate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + EPOCH_DURATION;
        emit EpochStarted(committed, rate, periodFinish);
    }

    /// @notice Add `amount` from the reserve to the running epoch without changing its end time.
    function boostEmissions(uint256 amount) external onlyEmissionsManager {
        if (block.timestamp >= periodFinish) revert NoActiveEpoch();
        if (amount == 0) revert ZeroAmount();
        _updateGlobalRewards();
        if (amount > rewardReserve) revert InsufficientRewardReserve(amount, rewardReserve);

        uint256 remaining = periodFinish - block.timestamp;
        uint256 total = amount + remaining * rewardRate;
        uint256 rate = total / remaining;
        uint256 committed = rate * remaining;

        rewardReserve = rewardReserve - amount + (total - committed);
        rewardRate = rate;
        lastUpdateTime = block.timestamp;
        emit EmissionsBoosted(amount, rate, periodFinish);
    }

    /// @notice Set the per-second rate for the rest of the running epoch. Raising it draws from the
    ///         reserve; lowering it returns the difference to the reserve. Zero pauses emissions.
    function setRewardRate(uint256 newRate) external onlyEmissionsManager {
        if (block.timestamp >= periodFinish) revert NoActiveEpoch();
        _updateGlobalRewards();

        uint256 remaining = periodFinish - block.timestamp;
        uint256 available = rewardReserve + remaining * rewardRate;
        uint256 needed = newRate * remaining;
        if (needed > available) revert InsufficientRewardReserve(needed, available);

        rewardReserve = available - needed;
        rewardRate = newRate;
        lastUpdateTime = block.timestamp;
        emit RewardRateSet(newRate, periodFinish);
    }

    /// @notice Return uncommitted reward reserve to the Treasury. Principal, committed emissions and
    ///         accrued rewards are never reachable here.
    function returnUncommittedRewards(uint256 amount) external onlyEmissionsManager nonReentrant {
        _updateGlobalRewards();
        if (amount == 0) revert ZeroAmount();
        if (amount > rewardReserve) revert InsufficientRewardReserve(amount, rewardReserve);
        rewardReserve -= amount;
        rewardToken.safeTransfer(treasury, amount);
        emit UncommittedRewardsReturned(treasury, amount);
    }

    /// @notice Send tokens that are neither staked nor rewarded here to the Treasury. Permissionless.
    function recoverERC20(address token) external nonReentrant {
        if (token == address(stakingToken) || token == address(rewardToken)) revert ProtectedToken();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(treasury, amount);
        emit TokenRecovered(token, amount);
    }

    // ----------------------------------------------------------------------------------------
    // Role management
    // ----------------------------------------------------------------------------------------

    function setEmissionsManager(address newManager) external onlyEmissionsManager {
        if (newManager == address(0)) revert ZeroAddress();
        emit EmissionsManagerTransferred(msg.sender, newManager);
        emissionsManager = newManager;
    }

    /// @notice Permanently give up emission control. No function can set the role again.
    function renounceEmissionsManager() external onlyEmissionsManager {
        emissionsManager = address(0);
        emit EmissionsManagerRenounced(msg.sender);
    }

    function setGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit GuardianTransferred(msg.sender, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Permanently give up emergency control. Deposits are unpaused so nothing stays stuck.
    function renounceGuardian() external onlyGuardian {
        guardian = address(0);
        if (depositsPaused) {
            depositsPaused = false;
            emit DepositsUnpaused(msg.sender);
        }
        emit GuardianRenounced(msg.sender);
    }

    function pauseDeposits() external onlyGuardian {
        depositsPaused = true;
        emit DepositsPaused(msg.sender);
    }

    function unpauseDeposits() external onlyGuardian {
        depositsPaused = false;
        emit DepositsUnpaused(msg.sender);
    }

    // ----------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------

    /// @notice The later of `lastUpdateTime` and the current time, capped at `periodFinish`.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Current cumulative LOCKER per staked unit (scaled by `PRECISION`).
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 applicable = lastTimeRewardApplicable();
        if (applicable <= lastUpdateTime) return rewardPerTokenStored;
        return rewardPerTokenStored + ((applicable - lastUpdateTime) * rewardRate).mulDiv(PRECISION, totalStaked);
    }

    /// @notice LOCKER rewards `account` could claim now.
    function earned(address account) public view returns (uint256) {
        return
            rewards[account] + balanceOf[account].mulDiv(rewardPerToken() - userRewardPerTokenPaid[account], PRECISION);
    }

    /// @notice Withdrawal-fee rewards `account` could claim now, in the staking token.
    function pendingFees(address account) public view returns (uint256) {
        return
            feesOwed[account] + balanceOf[account].mulDiv(feePerShareStored - userFeePerSharePaid[account], PRECISION);
    }

    /// @notice LOCKER still to be emitted by the running epoch.
    function remainingEpochRewards() external view returns (uint256) {
        return _leftover();
    }

    /// @notice Seconds until the running epoch ends; zero when none is running.
    function epochTimeRemaining() external view returns (uint256) {
        return block.timestamp < periodFinish ? periodFinish - block.timestamp : 0;
    }

    /// @notice LOCKER a full 30-day epoch emits at the current rate.
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * EPOCH_DURATION;
    }

    /// @notice Fee preview for withdrawing `amount` as `account` right now.
    /// @return payout what the withdrawer receives
    /// @return redistributed what the other depositors share
    /// @return toTreasury what the Treasury receives
    function previewWithdraw(address account, uint256 amount)
        external
        view
        returns (uint256 payout, uint256 redistributed, uint256 toTreasury)
    {
        uint256 fee = amount * WITHDRAWAL_FEE_BPS / BPS;
        payout = amount - fee;
        if (totalStaked - balanceOf[account] > 0) {
            redistributed = amount * REDISTRIBUTED_FEE_BPS / BPS;
        }
        toTreasury = fee - redistributed;
    }

    // ----------------------------------------------------------------------------------------
    // Internals
    // ----------------------------------------------------------------------------------------

    function _withdraw(address account, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[account];
        if (amount > bal) revert InsufficientBalance(amount, bal);
        _settle(account);

        uint256 fee = amount * WITHDRAWAL_FEE_BPS / BPS;
        uint256 payout = amount - fee;
        uint256 redistributed;
        uint256 others = totalStaked - bal;
        if (others > 0) {
            redistributed = amount * REDISTRIBUTED_FEE_BPS / BPS;
            feePerShareStored += redistributed.mulDiv(PRECISION, others);
            // The withdrawer never earns from their own fee, even with stake left in the farm.
            userFeePerSharePaid[account] = feePerShareStored;
        }
        uint256 toTreasury = fee - redistributed;

        balanceOf[account] = bal - amount;
        totalStaked -= amount;
        totalFeesRedistributed += redistributed;
        totalFeesToTreasury += toTreasury;
        emit Withdrawn(account, amount, payout, redistributed, toTreasury);

        stakingToken.safeTransfer(account, payout);
        if (toTreasury > 0) stakingToken.safeTransfer(treasury, toTreasury);
    }

    function _claimFees(address account) internal {
        uint256 amount = feesOwed[account];
        if (amount == 0) return;
        feesOwed[account] = 0;
        emit FeesClaimed(account, amount);
        stakingToken.safeTransfer(account, amount);
    }

    function _claimRewards(address account) internal {
        uint256 amount = rewards[account];
        if (amount == 0) return;
        rewards[account] = 0;
        emit RewardsClaimed(account, amount);
        rewardToken.safeTransfer(account, amount);
    }

    /// @dev Brings the global reward accumulator up to date, then checkpoints `account` for both
    ///      reward kinds.
    function _settle(address account) internal {
        _updateGlobalRewards();
        uint256 bal = balanceOf[account];
        rewards[account] += bal.mulDiv(rewardPerTokenStored - userRewardPerTokenPaid[account], PRECISION);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        feesOwed[account] += bal.mulDiv(feePerShareStored - userFeePerSharePaid[account], PRECISION);
        userFeePerSharePaid[account] = feePerShareStored;
    }

    /// @dev Accrues emissions since the last update. Emissions over a span with no stakers return
    ///      to the uncommitted reserve instead of being lost.
    function _updateGlobalRewards() internal {
        uint256 applicable = lastTimeRewardApplicable();
        if (applicable <= lastUpdateTime) return;
        uint256 emitted = (applicable - lastUpdateTime) * rewardRate;
        if (totalStaked == 0) {
            rewardReserve += emitted;
        } else {
            rewardPerTokenStored += emitted.mulDiv(PRECISION, totalStaked);
        }
        lastUpdateTime = applicable;
    }

    /// @dev LOCKER the running epoch has still to emit from now.
    function _leftover() internal view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (periodFinish - block.timestamp) * rewardRate;
    }
}
