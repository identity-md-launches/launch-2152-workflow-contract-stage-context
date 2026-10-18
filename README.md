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
* **Withdrawal fee: 10% of the withdrawn principal.** 9% is redistributed proportionally among the
  *other* depositors of the same farm; the withdrawing address is excluded even on a partial
  withdrawal (its checkpoint is moved past its own fee). 1% goes to the Treasury in the underlying
  token. If there are no other depositors, the whole 10% goes to the Treasury.
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
| Emissions manager | `LockerFarm.emissionsManager` (per farm) | `startEpoch`, `boostEmissions`, `setRewardRate`, `returnUncommittedRewards`, transfer role | `renounceEmissionsManager()` — permanent; the role can only be set by its current holder, and nobody is `address(0)`. |
| Guardian (emergency) | `LockerFarm.guardian` (per farm) | `pauseDeposits` / `unpauseDeposits`, transfer role | `renounceGuardian()` — permanent; deposits are unpaused on renounce so nothing is stuck. |

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
   `LockerFarm.fundRewards` after approving). This only raises the farm's reserve.
6. **Start each farm's first epoch**: `LockerFarm.startEpoch(<amount>)` as emissions manager.
   `amount` must be at least 2,592,000 wei of LOCKER (one wei per second) and at most the reserve.
7. **Frontend configuration**: point the site at the token, Treasury, factory and farm addresses from
   the launch handoff, and use the exact pool key the handoff supplies.

Later: `boostEmissions`, `setRewardRate`, further `startEpoch` calls and further `createFarm` calls
as needed; `pauseDeposits` for emergencies; the `renounce*` functions when the project decides to
decentralise, one role at a time, keeping the Treasury owner.

## Chosen constants

| Constant | Value | Where | Note |
|----------|-------|-------|------|
| `EPOCH_DURATION` | 30 days | `LockerFarm` | Given by the brief. |
| `WITHDRAWAL_FEE_BPS` / `REDISTRIBUTED_FEE_BPS` / `TREASURY_FEE_BPS` | 1000 / 900 / 100 | `LockerFarm` | 10% / 9% / 1%, given by the brief. |
| `PRECISION` | 1e18 | `LockerFarm` | Accumulator scale; all per-user math uses 512-bit `mulDiv`, so it cannot overflow. |
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
* Rounding: fees and rewards floor. A withdrawal under 10 wei pays no fee; per-share rounding leaves
  a few wei of dust in the farm (never a shortfall, see the invariant tests). Rewards emitted while
  nobody is staked return to the reserve; reward-per-token rounding dust stays in the farm.
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

Results on the authoring machine (forge 1.8.3, solc 0.8.26): 87 tests, 0 failures, with and without
the seed; `forge fmt --check` clean. The suite covers:

* `LaunchToken.t.sol` — name/symbol/decimals, whole supply to deployer, exact transfers, no mint or
  admin surface, fuzzed supply conservation.
* `LockerFarmFees.t.sol` — zero deposit fee, the 10% split, proportional redistribution, exclusion of
  the withdrawer on partial withdrawals, sole-depositor case, immediate and post-exit fee claims,
  double claims, late depositors, `exit`, fuzzed conservation and solvency.
* `LockerFarmRewards.t.sol` — funding without emission change, epoch start/roll-over, boosts, rate
  changes up/down/zero, insolvency reverts, principal and accrued rewards never re-committed
  (including on the LOCKER farm), no-staker recycling, fuzzed "never over-promises".
* `LockerFarmRoles.t.sol` — role separation, transfers, permanent renouncement (old holder, stranger
  and `address(0)` all rejected), pause semantics, Treasury powerlessness, token recovery.
* `LockerFarmReentrancy.t.sol` — a callback token attempting re-entrant `withdraw`, `claimFees`,
  `exit` and `deposit` is blocked by the guard.
* `LockerTreasury.t.sol` — refills, withdrawals, ETH handling, non-renounceable two-step ownership,
  no access to user deposits or rewards.
* `LockerFarmFactory.t.sol` — farm creation and registration, isolation of existing farms, permanent
  renouncement of farm creation.
* `DeployLocker.t.sol` — the script wires the launch owner everywhere and never the deployer.
* `LockerFarmInvariant.t.sol` — stateful fuzzing of a LOCKER-staking farm (the same-token case):
  solvency against all obligations, token-flow conservation and "emissions never exceed funding".

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
