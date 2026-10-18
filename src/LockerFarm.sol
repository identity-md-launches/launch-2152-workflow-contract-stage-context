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
///        A withdrawal of `amount` principal pays a 10% fee (rounded up): 9% is distributed
///        proportionally among the *other eligible* depositors of this farm (the withdrawer's
///        remaining stake is excluded even on a partial withdrawal) and 1% goes to the Treasury.
///        With no other eligible depositor, all 10% goes to the Treasury. Per-share rounding dust
///        (a few wei) stays in the farm, which keeps it solvent. Fee rewards are claimable at once,
///        with no further fee, and remain claimable after a full withdrawal.
///      - Fee eligibility has a time dimension so that a same-block, just-in-time or dust stake cannot
///        capture the 9% share: stake deposited during one `FEE_ELIGIBILITY_PERIOD` bucket becomes
///        eligible at the start of the bucket after next (between one and two periods later). Until
///        then it is "pending": it still earns LOCKER emissions and can be withdrawn (paying the
///        fee), but neither receives fee rewards nor counts as an "other depositor". Per account at
///        most two pending tranches exist (the current bucket and the previous one), and globally the
///        pending totals of those two buckets are kept, so maturation needs no iteration.
///      - For the LOCKER farm the staked token and the reward token are the same ERC-20. Principal,
///        fee rewards, the uncommitted reward reserve and committed emissions are tracked as separate
///        numbers, so the contract never pays one out of another.
///
///      Roles (each renounceable individually and permanently, none recoverable once renounced;
///      transfers are two-step, the new holder must accept):
///      - `emissionsManager`: starts epochs, boosts or re-rates the running epoch and may return
///        *uncommitted* reward reserve to the Treasury. Cannot touch principal or accrued rewards.
///        Renouncing requires an empty reserve; afterwards funding is refused and anyone may return
///        reserve that reappears (emissions recycled over no-staker spans) to the Treasury.
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
    /// @notice Length of one fee-eligibility bucket. Stake deposited in bucket `k` shares in
    ///         withdrawal fees from the start of bucket `k + 2`, i.e. after one to two periods.
    uint256 public constant FEE_ELIGIBILITY_PERIOD = 1 days;

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
    /// @notice Address that may accept the emissions-manager role (two-step transfer).
    address public pendingEmissionsManager;
    /// @notice Emergency role that can pause deposits. `address(0)` once renounced.
    address public guardian;
    /// @notice Address that may accept the guardian role (two-step transfer).
    address public pendingGuardian;
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
    /// @notice Lifetime LOCKER emitted to stakers (an upper bound on what they can claim).
    uint256 public totalRewardsEmitted;
    /// @notice Lifetime LOCKER rewards paid out.
    uint256 public totalRewardsClaimed;
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
    /// @notice Lifetime amount of redistributed fees paid out to depositors.
    uint256 public totalFeesClaimed;
    mapping(address account => uint256) public userFeePerSharePaid;
    mapping(address account => uint256) public feesOwed;

    // ----------------------------------------------------------------------------------------
    // Fee eligibility (time-bucketed)
    // ----------------------------------------------------------------------------------------

    /// @dev A deposit tranche that is not yet eligible for fee rewards.
    struct PendingStake {
        uint256 amount;
        uint256 bucket;
    }

    /// @notice Stake that is eligible for fee rewards, as of the last state change. Use
    ///         `eligibleTotalStaked()` for the live value.
    uint256 public eligibleStaked;
    /// @dev Bucket the two global pending counters refer to (`_pendingCurrent` is this bucket,
    ///      `_pendingPrevious` the one before).
    uint256 private _pendingBucket;
    uint256 private _pendingCurrent;
    uint256 private _pendingPrevious;
    /// @dev Up to two pending tranches per account, slot 0 the older.
    mapping(address account => PendingStake[2]) private _pending;
    /// @dev `feePerShareStored` as it was at the start of a bucket, recorded lazily for the buckets
    ///      in which tranches mature. An unrecorded bucket means nothing changed since its start.
    mapping(uint256 bucket => uint256) private _feePerShareAtBucketStart;
    mapping(uint256 bucket => bool) private _bucketStartRecorded;

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
    event RewardReserveSynced(uint256 amount, uint256 rewardReserve);
    event ExcessStakingTokenRecovered(uint256 amount);
    event EmissionsManagerTransferStarted(address indexed previousManager, address indexed newManager);
    event EmissionsManagerTransferred(address indexed previousManager, address indexed newManager);
    event EmissionsManagerRenounced(address indexed previousManager);
    event GuardianTransferStarted(address indexed previousGuardian, address indexed newGuardian);
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
    error NotPendingEmissionsManager();
    error NotPendingGuardian();
    error ReserveNotEmpty(uint256 rewardReserve);
    error EmissionsRenounced();

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
        _pendingBucket = block.timestamp / FEE_ELIGIBILITY_PERIOD;
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
        _addPending(msg.sender, received);
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
        if (emissionsManager == address(0)) revert EmissionsRenounced();
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
    ///         accrued rewards are never reachable here. Only the emissions manager may call this;
    ///         once the role is renounced anyone may, so reserve that reappears (emissions recycled
    ///         over a no-staker span) is never stranded. The destination is always the immutable
    ///         Treasury.
    function returnUncommittedRewards(uint256 amount) external nonReentrant {
        if (emissionsManager != address(0) && msg.sender != emissionsManager) revert NotEmissionsManager();
        _updateGlobalRewards();
        if (amount == 0) revert ZeroAmount();
        if (amount > rewardReserve) revert InsufficientRewardReserve(amount, rewardReserve);
        rewardReserve -= amount;
        rewardToken.safeTransfer(treasury, amount);
        emit UncommittedRewardsReturned(treasury, amount);
    }

    /// @notice Credit reward token held by the farm above every tracked liability (a plain
    ///         transfer made instead of `fundRewards`, or per-share rounding residue) to the
    ///         uncommitted reserve. Permissionless: the reserve is only ever committed by the
    ///         emissions manager or returned to the Treasury.
    function syncRewardReserve() external nonReentrant {
        _updateGlobalRewards();
        uint256 amount = untrackedBalance(address(rewardToken));
        if (amount == 0) revert ZeroAmount();
        rewardReserve += amount;
        emit RewardReserveSynced(amount, rewardReserve);
    }

    /// @notice Send staking token held above every tracked liability to the Treasury. Only for farms
    ///         whose staking token is not the reward token (there `syncRewardReserve` applies).
    ///         Permissionless.
    function recoverExcessStakingToken() external nonReentrant {
        if (address(stakingToken) == address(rewardToken)) revert ProtectedToken();
        uint256 amount = untrackedBalance(address(stakingToken));
        if (amount == 0) revert ZeroAmount();
        emit ExcessStakingTokenRecovered(amount);
        stakingToken.safeTransfer(treasury, amount);
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
    // Role management (two-step transfers; renouncement is permanent)
    // ----------------------------------------------------------------------------------------

    /// @notice Offer the emissions-manager role to `newManager`, who must accept it. Passing
    ///         `address(0)` cancels a pending offer. The current holder keeps the role until then.
    function setEmissionsManager(address newManager) external onlyEmissionsManager {
        pendingEmissionsManager = newManager;
        emit EmissionsManagerTransferStarted(msg.sender, newManager);
    }

    /// @notice Accept a pending emissions-manager offer.
    function acceptEmissionsManager() external {
        if (msg.sender != pendingEmissionsManager || msg.sender == address(0)) revert NotPendingEmissionsManager();
        emit EmissionsManagerTransferred(emissionsManager, msg.sender);
        emissionsManager = msg.sender;
        pendingEmissionsManager = address(0);
    }

    /// @notice Permanently give up emission control. No function can set the role again. Refused
    ///         while uncommitted reserve remains: return it to the Treasury or commit it first.
    function renounceEmissionsManager() external onlyEmissionsManager {
        _updateGlobalRewards();
        if (rewardReserve > 0) revert ReserveNotEmpty(rewardReserve);
        emissionsManager = address(0);
        pendingEmissionsManager = address(0);
        emit EmissionsManagerRenounced(msg.sender);
    }

    /// @notice Offer the guardian role to `newGuardian`, who must accept it. `address(0)` cancels.
    function setGuardian(address newGuardian) external onlyGuardian {
        pendingGuardian = newGuardian;
        emit GuardianTransferStarted(msg.sender, newGuardian);
    }

    /// @notice Accept a pending guardian offer.
    function acceptGuardian() external {
        if (msg.sender != pendingGuardian || msg.sender == address(0)) revert NotPendingGuardian();
        emit GuardianTransferred(guardian, msg.sender);
        guardian = msg.sender;
        pendingGuardian = address(0);
    }

    /// @notice Permanently give up emergency control. Deposits are unpaused so nothing stays stuck.
    function renounceGuardian() external onlyGuardian {
        guardian = address(0);
        pendingGuardian = address(0);
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
        uint256 cur = _currentBucket();
        uint256 owed = feesOwed[account];
        uint256 wasPending;
        for (uint256 i; i < 2; ++i) {
            PendingStake memory slot = _pending[account][i];
            if (slot.amount == 0) continue;
            wasPending += slot.amount;
            if (cur >= slot.bucket + 2) {
                owed += slot.amount.mulDiv(feePerShareStored - _feePerShareAtStartOf(slot.bucket + 2), PRECISION);
            }
        }
        return
            owed + (balanceOf[account] - wasPending).mulDiv(feePerShareStored - userFeePerSharePaid[account], PRECISION);
    }

    /// @notice Part of `account`'s principal that is not yet eligible for fee rewards.
    function pendingStakeOf(address account) public view returns (uint256 pending) {
        uint256 cur = _currentBucket();
        for (uint256 i; i < 2; ++i) {
            PendingStake memory slot = _pending[account][i];
            if (slot.amount != 0 && cur < slot.bucket + 2) pending += slot.amount;
        }
    }

    /// @notice Part of `account`'s principal that shares in withdrawal fees right now.
    function eligibleStakeOf(address account) public view returns (uint256) {
        return balanceOf[account] - pendingStakeOf(account);
    }

    /// @notice Total stake that shares in withdrawal fees right now.
    function eligibleTotalStaked() public view returns (uint256) {
        uint256 cur = _currentBucket();
        uint256 p = _pendingBucket;
        if (cur == p) return eligibleStaked;
        if (cur == p + 1) return eligibleStaked + _pendingPrevious;
        return eligibleStaked + _pendingPrevious + _pendingCurrent;
    }

    /// @notice Timestamp from which stake deposited right now would share in withdrawal fees.
    function feeEligibilityStart() external view returns (uint256) {
        return (_currentBucket() + 2) * FEE_ELIGIBILITY_PERIOD;
    }

    /// @notice Balance of `token` held by the farm above every tracked liability: principal, unpaid
    ///         fee rewards, the uncommitted reserve, emitted-but-unclaimed rewards and the rest of the
    ///         running epoch. Liabilities are counted as upper bounds, so this never over-states.
    function untrackedBalance(address token) public view returns (uint256) {
        uint256 liabilities;
        if (token == address(stakingToken)) {
            liabilities += totalStaked + totalFeesRedistributed - totalFeesClaimed;
        }
        if (token == address(rewardToken)) {
            uint256 unaccrued = periodFinish > lastUpdateTime ? (periodFinish - lastUpdateTime) * rewardRate : 0;
            liabilities += rewardReserve + unaccrued + totalRewardsEmitted - totalRewardsClaimed;
        }
        uint256 held = IERC20(token).balanceOf(address(this));
        return held > liabilities ? held - liabilities : 0;
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
    /// @return redistributed what the other eligible depositors share
    /// @return toTreasury what the Treasury receives
    function previewWithdraw(address account, uint256 amount)
        external
        view
        returns (uint256 payout, uint256 redistributed, uint256 toTreasury)
    {
        uint256 fee = amount.mulDiv(WITHDRAWAL_FEE_BPS, BPS, Math.Rounding.Ceil);
        payout = amount - fee;
        if (eligibleTotalStaked() - eligibleStakeOf(account) > 0) {
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

        // The fee rounds up, so every withdrawal pays and the Treasury always receives its share.
        uint256 fee = amount.mulDiv(WITHDRAWAL_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 payout = amount - fee;
        uint256 redistributed;
        // Only stake that is past its eligibility delay, and not the withdrawer's, shares the 9%.
        uint256 others = eligibleStaked - (bal - _pendingSettled(account));
        _removePending(account, amount);
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
        totalFeesClaimed += amount;
        emit FeesClaimed(account, amount);
        stakingToken.safeTransfer(account, amount);
    }

    function _claimRewards(address account) internal {
        uint256 amount = rewards[account];
        if (amount == 0) return;
        rewards[account] = 0;
        totalRewardsClaimed += amount;
        emit RewardsClaimed(account, amount);
        rewardToken.safeTransfer(account, amount);
    }

    /// @dev Brings the global accumulators up to date, matures `account`'s pending tranches that
    ///      have passed their delay, then checkpoints `account` for both reward kinds.
    function _settle(address account) internal {
        _updateGlobalRewards();
        _rollFeeBuckets();
        uint256 bal = balanceOf[account];
        rewards[account] += bal.mulDiv(rewardPerTokenStored - userRewardPerTokenPaid[account], PRECISION);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;

        uint256 cur = _currentBucket();
        PendingStake[2] storage slots = _pending[account];
        uint256 owed;
        // Every tranche still recorded was pending at the account's last checkpoint, so none of it
        // is covered by `userFeePerSharePaid`; a matured one is credited from its own start instead.
        uint256 wasPending;
        for (uint256 i; i < 2; ++i) {
            uint256 amt = slots[i].amount;
            if (amt == 0) continue;
            wasPending += amt;
            if (cur >= slots[i].bucket + 2) {
                owed += amt.mulDiv(feePerShareStored - _feePerShareAtStartOf(slots[i].bucket + 2), PRECISION);
                slots[i].amount = 0;
            }
        }
        if (slots[0].amount == 0 && slots[1].amount != 0) {
            slots[0] = slots[1];
            delete slots[1];
        }
        owed += (bal - wasPending).mulDiv(feePerShareStored - userFeePerSharePaid[account], PRECISION);
        feesOwed[account] += owed;
        userFeePerSharePaid[account] = feePerShareStored;
    }

    /// @dev Records `received` as a pending tranche of the current bucket. Must run after `_settle`.
    function _addPending(address account, uint256 received) internal {
        uint256 cur = _currentBucket();
        PendingStake[2] storage slots = _pending[account];
        if (slots[0].amount != 0 && slots[0].bucket == cur) {
            slots[0].amount += received;
        } else if (slots[0].amount == 0) {
            slots[0] = PendingStake(received, cur);
        } else if (slots[1].amount != 0) {
            // After `_settle` the only possible layout is slot 0 = previous bucket, slot 1 = current.
            slots[1].amount += received;
        } else {
            slots[1] = PendingStake(received, cur);
        }
        _pendingCurrent += received;
    }

    /// @dev Pending total of an account whose tranches were just matured by `_settle`.
    function _pendingSettled(address account) internal view returns (uint256) {
        return _pending[account][0].amount + _pending[account][1].amount;
    }

    /// @dev Takes a withdrawal of `amount` out of the account's pending tranches first (newest
    ///      first), then out of eligible stake. Must run after `_settle`.
    function _removePending(address account, uint256 amount) internal {
        uint256 cur = _currentBucket();
        PendingStake[2] storage slots = _pending[account];
        uint256 remaining = amount;
        for (uint256 i = 2; i > 0 && remaining > 0; --i) {
            PendingStake storage slot = slots[i - 1];
            uint256 amt = slot.amount;
            if (amt == 0) continue;
            uint256 take = remaining < amt ? remaining : amt;
            slot.amount = amt - take;
            remaining -= take;
            if (slot.bucket == cur) {
                _pendingCurrent -= take;
            } else {
                _pendingPrevious -= take;
            }
        }
        eligibleStaked -= remaining;
    }

    /// @dev Moves the global pending totals along when a new bucket has started: the bucket before
    ///      the previous one has matured. Records `feePerShareStored` for the buckets in which the
    ///      currently pending tranches mature (nothing changed it since those buckets started).
    function _rollFeeBuckets() internal {
        uint256 cur = _currentBucket();
        uint256 p = _pendingBucket;
        if (cur == p) return;
        _recordBucketStart(p + 1);
        if (cur >= p + 2) {
            _recordBucketStart(p + 2);
            eligibleStaked += _pendingPrevious + _pendingCurrent;
            _pendingPrevious = 0;
        } else {
            eligibleStaked += _pendingPrevious;
            _pendingPrevious = _pendingCurrent;
        }
        _pendingCurrent = 0;
        _pendingBucket = cur;
    }

    function _recordBucketStart(uint256 bucket) internal {
        if (_bucketStartRecorded[bucket]) return;
        _bucketStartRecorded[bucket] = true;
        _feePerShareAtBucketStart[bucket] = feePerShareStored;
    }

    /// @dev `feePerShareStored` as it was at the start of `bucket` (which must not be in the
    ///      future). If it was never recorded, nothing has changed it since that moment.
    function _feePerShareAtStartOf(uint256 bucket) internal view returns (uint256) {
        return _bucketStartRecorded[bucket] ? _feePerShareAtBucketStart[bucket] : feePerShareStored;
    }

    function _currentBucket() internal view returns (uint256) {
        return block.timestamp / FEE_ELIGIBILITY_PERIOD;
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
            totalRewardsEmitted += emitted;
        }
        lastUpdateTime = applicable;
    }

    /// @dev LOCKER the running epoch has still to emit from now.
    function _leftover() internal view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (periodFinish - block.timestamp) * rewardRate;
    }
}
