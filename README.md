# Locker ($LOCKER) — farming contracts

Smart contracts for **Locker**, a DeFi farming platform launched on Ethereum Sepolia (chain id
11155111) through the IMD project launch. This repository is the *contract stage* of the launch: the
LOCKER token, the farming pools, the Treasury, the farm factory, their tests and ABI exports. The
website, the manifest (`launch.json`) and the on-chain deployment are produced by later stages and
are not part of this tree.

Everything is a standard Foundry project at the repository root (`forge build`, `forge test`,
`forge fmt --check`). Dependencies (forge-std 1.9.7, OpenZeppelin Contracts 5.1.0) are vendored as
plain files under `lib/`.

## Contracts

| Contract            | File                          | Purpose |
|---------------------|-------------------------------|---------|
| `LaunchToken`       | `src/LaunchToken.sol`         | LOCKER: fixed-supply ERC-20, 1,000,000,000 × 10^18 minted once to the deployer (the launch factory). No owner, mint, pause, blocklist, fee or upgrade. |
| `LockerTreasury`    | `src/LockerTreasury.sol`      | Owner-controlled vault. Receives the 1% Treasury share of withdrawal fees, holds the protocol's LOCKER and refills farm reward balances on the owner's instruction. Ownership is two-step and **cannot be renounced**. |
| `LockerFarmFactory` | `src/LockerFarmFactory.sol`   | Registry and factory. The owner creates new, isolated farms for additional tokens at any time; existing farms are untouched. Renouncing its ownership permanently ends farm creation. |
| `LockerFarm`        | `src/LockerFarm.sol`          | One farming pool: isolated deposits, withdrawal-fee redistribution, its own LOCKER reward reserve and its own 30-day emission schedule. Deployed once at launch for LOCKER staking and again by the factory for IMD and sIMD. |

ABI exports for the frontend live in `docs/abi/<Contract>.json` (generated with
`forge inspect <Contract> abi --json`).

### Farming architecture

The farms use two established accumulator designs rather than a MasterChef:

* **LOCKER emissions** follow the Synthetix `StakingRewards` model (`rewardPerTokenStored`,
  `rewardRate`, `periodFinish`). Rewards are distributed by stake and time over fixed 30-day epochs.
* **Withdrawal-fee redistribution** follows a MasterChef-style fee-per-share accumulator in the
  staked token (`feePerShareStored`), so the 9% share is split proportionally among the other
  depositors in O(1).

Each farm is a separate contract with its own token balances, so deposits, fee accounting, reward
funding and schedules are isolated by construction.

### Economic rules (as specified, unchanged)

* **Deposit fee: 0%.**
* **Withdrawal fee: 10% of the withdrawn principal** (rounded up to the wei, so even a 1-wei
  withdrawal pays). 9% is redistributed proportionally among the *other eligible* depositors of the
  same farm; the withdrawing address is excluded even on a partial withdrawal (its checkpoint is
  moved past its own fee). 1% goes to the Treasury in the underlying token. If there are no other
  eligible depositors, the whole 10% goes to the Treasury.
* **Fee eligibility has a delay** (`FEE_ELIGIBILITY_PERIOD` = 1 day). Stake deposited during one
  period becomes eligible for fee rewards at the start of the period after next, i.e. between 24 and
  48 hours after the deposit (`feeEligibilityStart()` returns the exact timestamp for a deposit made
  now). Until then the stake is *pending*: it earns LOCKER emissions normally and can be withdrawn
  (paying the fee), but it neither receives fee rewards nor counts as an "other depositor". This is
  what makes "no other eligible depositors" meaningful: a dust or same-block wallet, a front-run
  deposit or a just-in-time deposit cannot take the Treasury's 10% or dilute the long-term
  depositors' 9%. Withdrawals come out of pending stake first, so a top-up never costs eligible
  stake. `pendingStakeOf`, `eligibleStakeOf` and `eligibleTotalStaked` expose the split for the
  frontend.
* **Fee rewards** are claimable at once (`claimFees`) in the underlying token with no further fee, and
  remain claimable after a full withdrawal.
* **LOCKER rewards** accrue by stake and time. Each farm has its own reward reserve and 30-day epoch.
  Anyone may fund a farm (`fundRewards`); funding **never** changes emissions. The emissions manager
  commits reserve to a schedule with `startEpoch(amount)` (new 30-day epoch, leftover of the running
  one rolls in), `boostEmissions(amount)` (raise the rate until the current end) or
  `setRewardRate(rate)` (re-rate the remainder; lowering returns funds to the reserve). Every one of
  these checks the reserve, so emissions can never be backed by user principal, accrued LOCKER
  rewards or accrued fee rewards. On the LOCKER farm, staked LOCKER principal, fee rewards, the
  uncommitted reserve and committed emissions are tracked as separate numbers.
* Emissions over a period with **no stakers** are returned to the farm's uncommitted reserve instead
  of being lost.
* The emissions manager may return *uncommitted* reserve to the Treasury
  (`returnUncommittedRewards`). Principal and accrued rewards are never reachable by any role.

### Roles and renouncement

| Role | Where | Powers | Renounce |
|------|-------|--------|----------|
| Treasury owner | `LockerTreasury.owner()` | Withdraw Treasury balances, refill farms | **Not possible** (`renounceOwnership` reverts). Transfer is two-step. |
| Farm creation | `LockerFarmFactory.owner()` | `createFarm`, `registerFarm` | `renounceOwnership()` — permanent. After it, no caller (including `address(0)`) passes `onlyOwner`. |
| Emissions manager | `LockerFarm.emissionsManager` (per farm) | `startEpoch`, `boostEmissions`, `setRewardRate`, `returnUncommittedRewards`, offer role | `renounceEmissionsManager()` — permanent. Whatever uncommitted reserve remains is sent to the Treasury in the same transaction (event `UncommittedRewardsReturned`), so a third party cannot block the renounce by adding 1 wei to the reserve, and nothing is stranded. The running epoch is untouched. Afterwards `fundRewards` is refused and `returnUncommittedRewards` becomes permissionless, so reserve that reappears (emissions recycled over a no-staker span) always has a path to the Treasury. |
| Guardian (emergency) | `LockerFarm.guardian` (per farm) | `pauseDeposits` / `unpauseDeposits`, offer role | `renounceGuardian()` — permanent; deposits are unpaused on renounce so nothing is stuck. |

Farm role transfers are **two-step**, like the Treasury's and factory's `Ownable2Step`: the holder
calls `setEmissionsManager(new)` / `setGuardian(new)`, which only records an offer, and the new
holder must call `acceptEmissionsManager()` / `acceptGuardian()`. A mistyped address therefore
cannot lose the role; the holder can replace or cancel the offer (`set…(address(0))`) until it is
accepted, and renouncing clears any pending offer.

Withdrawals and claims can never be paused. There are no proxies, no `DELEGATECALL`, no
`SELFDESTRUCT`, no hidden admin and no upgrade path, so a renounced role cannot be restored. At launch
every role is held by the launch owner; **no role is renounced at launch.**

The fee recipient of each farm (`treasury`) is immutable. The Treasury itself has no privilege over
any farm: it only holds its own balances and can call the permissionless `fundRewards`, so it can
never reach user deposits or accrued rewards.

### Buybacks and LP fees

All of this is manual, by the owner, exactly as the brief requires: the owner withdraws fee tokens or
LOCKER from the Treasury (`withdrawToken`), performs the Treasury/Team split (80/20) and any
buyback from their own wallet, and refills a farm with `fundFarm(farm, amount)`. No contract trades
automatically. The pool's 1.25% trading fee is handled by the launch factory and is not implemented
here.

## Launch deployment parameters

The launch deploys the token and then the application contracts below, in this dependency order,
with the factory as `msg.sender`. Every constructor is nonpayable, performs no external calls and
only stores addresses, so it runs on an empty chain. Constructor argument counts are 0, 2, 3 and 4.

| Order | Contract            | Constructor arguments (declaration order) |
|-------|---------------------|-------------------------------------------|
| 0     | `LaunchToken`       | none |
| 1     | `LockerTreasury`    | `owner_` = `$owner`, `lockerToken_` = `$token` |
| 2     | `LockerFarmFactory` | `owner_` = `$owner`, `rewardToken_` = `$token`, `treasury_` = `$contract:LockerTreasury` |
| 3     | `LockerFarm`        | `stakingToken_` = `$token`, `rewardToken_` = `$token`, `treasury_` = `$contract:LockerTreasury`, `admin_` = `$owner` |

`$owner` is the launch owner (0xDEA11b3A70b77134424d436f6eb455f1Abbd4449), who becomes Treasury
owner, factory owner and the LOCKER farm's emissions manager and guardian. Nothing is ever owned by
the factory (`msg.sender`) or by IMD's launch wallet (`tx.origin`). The LOCKER farm's Solidity name
is `LockerFarm`; if the manifest needs a distinct identifier for it, `LockerFarm` (10 chars) is the
contract name to record.

Launch-decided values that this repository does not set: supply split (10% swarm, 30% pool,
60% requester wallet), pool fee 12500 (1.25%), tick spacing 60, pool pairing and opening price.
The manifest step writes `launch.json`; there is deliberately none in this tree.

`script/DeployLocker.s.sol` reproduces the same wiring for local review and is exercised by
`test/DeployLocker.t.sol`. It is documentation of the constructor wiring only: IMD's deployer performs
the real launch, and no contributor task broadcasts transactions.

## After launch — owner checklist

Values only the requester has (the IMD and sIMD token addresses on Sepolia) are **not** constructor
arguments; the owner creates those farms from their wallet once the launch has finished. Each step is
an owner-only call that emits an event.

1. **Register the LOCKER farm** so the frontend can enumerate it:
   `LockerFarmFactory.registerFarm(<LockerFarm address from the launch>)`.
2. **Create the IMD farm**: `LockerFarmFactory.createFarm(<IMD token address>, <owner address>)`.
   The IMD token is the chain's pair token published by IMD for Sepolia (`network.pairToken` in the
   network references). Use the ERC-20 contract address, not a pool.
3. **Create the sIMD farm**: `LockerFarmFactory.createFarm(<sIMD token address>, <owner address>)`.
   sIMD is the staked-IMD token from IMD's staking contract on Sepolia. It must be a plain,
   non-rebasing ERC-20 (see limitations); if the live sIMD rebases, use its wrapped non-rebasing form.
4. **Fund the Treasury**: transfer 50% of the LOCKER supply (500,000,000 LOCKER) from the requester
   wallet to the `LockerTreasury` address with a normal ERC-20 transfer, as planned in the brief.
5. **Refill each farm**: `LockerTreasury.fundFarm(<farm>, <amount>)` (or anyone may call
   `LockerFarm.fundRewards` after approving). This only raises the farm's reserve. Both revert on a
   farm whose emissions manager has been renounced. Never send LOCKER to a farm with a plain
   transfer: it is not credited to the reserve. If it happens anyway, anyone can call
   `syncRewardReserve()` to credit the untracked balance (`untrackedBalance(token)`) to the
   reserve; on the IMD and sIMD farms a stray transfer of the *staking* token is sent to the Treasury
   by `recoverExcessStakingToken()`.
6. **Start each farm's first epoch**: `LockerFarm.startEpoch(<amount>)` as emissions manager.
   `amount` must be at least 2,592,000 wei of LOCKER (one wei per second) and at most the reserve.
7. **Frontend configuration**: point the site at the token, Treasury, factory and farm addresses from
   the launch handoff, and use the exact pool key the handoff supplies.

Later: `boostEmissions`, `setRewardRate`, further `startEpoch` calls and further `createFarm` calls
as needed; `pauseDeposits` for emergencies; the `renounce*` functions when the project decides to
decentralise, one role at a time, keeping the Treasury owner. `renounceEmissionsManager` is a single
transaction: commit with `startEpoch` first whatever the farm should still emit, because any
uncommitted reserve left at that moment (including reserve a stranger adds or emissions recycled
while nobody was staked) is swept to the Treasury by the renounce itself. No preparatory
`returnUncommittedRewards` or `setRewardRate(0)` is needed, and no third party can make the renounce
revert. Role hand-overs to a multisig need the multisig to call `accept…` before the old key is
retired.

## Chosen constants

| Constant | Value | Where | Note |
|----------|-------|-------|------|
| `EPOCH_DURATION` | 30 days | `LockerFarm` | Given by the brief. |
| `WITHDRAWAL_FEE_BPS` / `REDISTRIBUTED_FEE_BPS` / `TREASURY_FEE_BPS` | 1000 / 900 / 100 | `LockerFarm` | 10% / 9% / 1%, given by the brief. |
| `PRECISION` | 1e18 | `LockerFarm` | Accumulator scale; all per-user math uses 512-bit `mulDiv`, so it cannot overflow. |
| `FEE_ELIGIBILITY_PERIOD` | 1 day | `LockerFarm` | Chosen here (the brief leaves it open). Stake shares in withdrawal fees from the start of the period after the one it was deposited in (24–48 h). Long enough that a dust or just-in-time stake cannot capture a fee in the same block or day; short enough not to matter to a 30-day farmer. |
| `TOTAL_SUPPLY` | 1e27 | `LaunchToken` | Launch policy. |

## Assumptions and deviations from the brief

* **Pool pairing.** The brief says "paired with IMD"; the launch section for this job fixes the pool's
  paired currency as native ETH (zero address) and the fee as 12500 (1.25%). Those are launch policy
  values, so they are left to the launch and the manifest step, and this README does not describe
  the pool at any other fee. The farms themselves stake IMD and sIMD regardless of the pool pair.
* **Token splits.** The LOCKER token mints the whole supply to the factory; the 50% Treasury
  allocation is a post-launch transfer by the requester (step 4 above), not a mint-time split.
* **Standard launch token.** Nothing in the brief asked the token to do anything non-standard, and it
  does nothing non-standard: no fees, limits, minting, pausing or owner.
* **Website and addresses.** The pixel-art site, the Admin Dashboard and the deployed contract
  addresses are produced by later stages (frontend and launch). The ABIs they need are in
  `docs/abi/`. Farming APR can be derived on the frontend from `rewardRate`, `totalStaked` and
  `periodFinish`; historical withdrawal-fee APR from `totalFeesRedistributed` and `Withdrawn`
  events. When data is missing the site should show "APR unavailable".
* **Who is "Team".** The 80/20 Treasury/Team split of LP fees is a manual off-chain action by the
  owner; no Team address is stored on chain.
* **Fee-eligibility delay.** The brief's rules "9% to the other depositors", "exclude the
  withdrawing address" and "all 10% to the Treasury if no other eligible depositors exist" were
  implemented literally in the first version, and the independent review showed that made them
  hollow: a 1-wei stake from a second wallet, or a deposit in the withdrawal's block, counted as an
  "other depositor" and took the 9% (and, for a sole depositor, 90% of the Treasury's share). The
  delay above is the chosen reading of *eligible*. It is the one economic parameter added to the
  brief's rules; the percentages and recipients are unchanged. A patient sybil that stakes a second
  wallet more than two days ahead is still indistinguishable from a genuine depositor on chain, and
  no contract rule can tell them apart; the delay removes the free, atomic versions of the trick and
  makes the pre-positioned one pay the fee on its own exit. **For the requester to confirm:** with
  the one-day period, a deposit made on day *N* earns nothing from withdrawals made on days *N* and
  *N+1*, and while such stake is the only other stake in the farm the Treasury receives the full 10%
  of those withdrawals. A different period, or a different reading of "eligible", is a one-constant
  change (`FEE_ELIGIBILITY_PERIOD`) but an economic decision that is the requester's to make.
* **Fee rounding** favours the protocol: the 10% rounds up to the wei, the 9% share rounds down and
  the Treasury receives the difference, so no withdrawal, however small, escapes the fee.

## Operational responsibilities and trust assumptions

* The **owner** holds every role at launch and is trusted to: keep the Treasury key safe (it holds
  50% of the supply), fund farms honestly, set emission rates, pause deposits only in emergencies,
  and transfer roles to a multisig before renouncing them.
* The emissions manager can **stop** emissions (`setRewardRate(0)`) and pull **uncommitted** reserve
  back to the Treasury; it cannot touch principal or accrued rewards.
* The guardian can **pause deposits** only; users can always withdraw and claim.
* Staked tokens must be plain ERC-20s. Deposits credit the amount actually received (fee-on-transfer
  tokens are credited correctly, but their withdrawals deliver less than `payout`). **Rebasing tokens
  are not supported**: balances changing without transfers would break the principal accounting.
* Rounding: the withdrawal fee rounds up, rewards and per-share accumulators round down. Per-share
  rounding leaves a few wei of dust in the farm (never a shortfall, see the invariant tests), which
  `syncRewardReserve` can fold back into the reserve. Rewards emitted while nobody is staked return
  to the reserve.
* Renouncing the emissions manager is final. The renounce sweeps the uncommitted reserve to the
  immutable Treasury in the same transaction (a permissionless move the contract already allows after
  the renounce, so the sweep gives no caller a new power), refuses new funding afterwards, and lets
  anyone return later-recycled reserve to the Treasury, so no LOCKER can be stranded by the renounce
  and nobody can block it. Tokens sent to a farm by plain transfer are
  recoverable through `syncRewardReserve` / `recoverExcessStakingToken` (to the reserve or the
  Treasury, never to a caller).
* **Not audited.** Tests passing is not an audit. The contracts hold user funds and need the
  independent adversarial review that follows this stage before release.

## Verification

```sh
forge build
forge test
forge fmt --check
# with the verifier's fuzz seed
FOUNDRY_FUZZ_SEED=0x854336ea9d255bb73b298897b5ed19b6b1f127e0d9e91079beedf983f2109bd1 forge test
```

Results on the authoring machine (forge 1.8.3, solc 0.8.26) for the previously accepted revision:
106 tests, 0 failures, with and without the seed; `forge fmt --check` clean. The latest revision
(the renounce sweep and its five tests, replacing one test that asserted the old `ReserveNotEmpty`
revert) could **not** be executed by the author: the authoring machine's shell sandbox refused to
start any process in both rounds. The job's own check harness did build and run it: 110 tests, of
which 107 passed and 3 failed on a fixture bug in the three new tests (`vm.prank(OWNER)` was
consumed by an inline `rewardReserve()` view call, so `returnUncommittedRewards` ran as the test
contract and reverted `NotEmissionsManager`). The reserve read is now hoisted above the prank, as
the other role tests already do; the contract was unchanged by that repair. The independent
verifier's run is the authoritative result. The suite covers:

* `LaunchToken.t.sol` — name/symbol/decimals, whole supply to deployer, exact transfers, no mint or
  admin surface, fuzzed supply conservation.
* `LockerFarmFees.t.sol` — zero deposit fee, the 10% split, proportional redistribution, exclusion of
  the withdrawer on partial withdrawals, sole-depositor case, immediate and post-exit fee claims,
  double claims, late depositors, `exit`, fuzzed conservation and solvency.
* `LockerFarmFeeEligibility.t.sol` — the eligibility delay: the reviewer's dust-wallet and
  same-block scenarios (Treasury receives the full 10%), the just-in-time depositor (earns nothing,
  pays to leave), pending stake earning emissions and being withdrawable, maturity at the exact
  bucket boundary, single crediting of matured tranches, consecutive-day tranches, pending-first
  withdrawals, previews, fee rounding (fuzzed) and fuzzed solvency / `eligible + pending == staked`.
* `LockerFarmRewards.t.sol` — funding without emission change, epoch start/roll-over, boosts, rate
  changes up/down/zero, insolvency reverts, principal and accrued rewards never re-committed
  (including on the LOCKER farm), no-staker recycling, fuzzed "never over-promises".
* `LockerFarmRoles.t.sol` — role separation, two-step transfers (offer, wrong acceptor, cancel,
  replace), permanent renouncement (old holder, former offeree, stranger and `address(0)` all
  rejected), the renounce sweeping leftover reserve to the Treasury while leaving the running epoch
  intact, a stranger's 1-wei `fundRewards` or donation-plus-`syncRewardReserve` front-run not
  blocking the renounce, the renounce going through while a no-staker epoch recycles emissions,
  funding refused and permissionless return to the Treasury after renounce, pause semantics,
  Treasury powerlessness, token recovery and the untracked-balance sync.
* `LockerFarmReentrancy.t.sol` — a callback token attempting re-entrant `withdraw`, `claimFees`,
  `exit` and `deposit` is blocked by the guard.
* `LockerTreasury.t.sol` — refills, withdrawals, ETH handling, non-renounceable two-step ownership,
  no access to user deposits or rewards.
* `LockerFarmFactory.t.sol` — farm creation and registration, isolation of existing farms, permanent
  renouncement of farm creation.
* `DeployLocker.t.sol` — the script wires the launch owner everywhere and never the deployer.
* `LockerFarmInvariant.t.sol` — stateful fuzzing of a LOCKER-staking farm (the same-token case):
  solvency against all obligations, token-flow conservation, `eligible + pending == staked` and
  "emissions never exceed funding".

Slither/Mythril were not available in this environment and did not run.

## Repository layout

```
foundry.toml          solc 0.8.26, optimizer, bytecode_hash = "none", no ffi / fs access
remappings.txt        forge-std/ and @openzeppelin/contracts/
src/                  LaunchToken, LockerFarm, LockerFarmFactory, LockerTreasury, interfaces/
script/               DeployLocker.s.sol (local reproduction of the launch wiring)
test/                 unit, fuzz, reentrancy and invariant tests (+ mocks/)
docs/abi/             ABI JSON per contract
lib/                  vendored forge-std and OpenZeppelin Contracts
```
