# VillaVault Operating Instructions

## Overview

VillaVault is an ERC-4626 vault that wraps Maple Syrup USDT pool. Users deposit USDT and receive Villa tokens representing their share of the pooled Syrup position.

**Key facts:**
- **Management Fee:** 1% of deposits (deducted at deposit time in USDT)
- **Performance Fee:** 5% of profits above the high-water mark (accrued via share dilution)
- **Withdrawals:** Asynchronous — two-step process via Maple's withdrawal queue

---

## Interacting via Etherscan

### Prerequisites

1. USDT in your wallet
2. MetaMask (or equivalent) connected to the correct network

### Step 1: Approve USDT

1. Go to the **USDT contract** on Etherscan:
   - Mainnet: `0xdAC17F958D2ee523a2206206994597C13D831ec7`
   - Sepolia: `0xaa8e23Fb1079EA71e0a56F48a2aA51851D8433D0`
2. Navigate to **Write Contract** → Connect Wallet
3. Call `approve`:
   - `spender`: VillaVault contract address
   - `amount`: Amount in 6-decimal units (e.g., `10000000000` for 10,000 USDT)
4. Confirm the transaction

### Step 2: Deposit USDT

1. Go to the **VillaVault contract** on Etherscan
2. Navigate to **Write Contract** → Connect Wallet
3. Call `deposit`:
   - `assets`: Amount of USDT (6 decimals). Example: `10000000000` = 10,000 USDT
   - `receiver`: Your wallet address
4. Confirm the transaction
5. You will receive Villa tokens. A 1% management fee is sent to the fee recipient.

### Step 3: Check Your Balance

1. Go to VillaVault → **Read Contract**
2. Call `balanceOf` with your address to see your Villa token balance
3. Call `convertToAssets` with your Villa balance to see the current USDT value

### Step 4: Request Withdrawal

1. Go to VillaVault → **Write Contract**
2. Call `redeem`:
   - `shares`: Number of Villa tokens to redeem (6 decimals)
   - `receiver`: Address to receive USDT when processed
   - `owner`: Your wallet address
3. Confirm the transaction
4. Your Villa tokens are burned and Syrup shares enter Maple's withdrawal queue
5. **Note:** This returns 0 assets immediately — the withdrawal is asynchronous

### Step 5: Process Withdrawal (Claim)

After Maple processes the withdrawal queue (timing depends on Maple's queue):

1. Go to VillaVault → **Write Contract**
2. Call `processRedeem`:
   - `owner`: The address that submitted the withdrawal request
3. Confirm the transaction
4. USDT is transferred to the receiver address specified in Step 4

### Checking Withdrawal Status

1. Go to VillaVault → **Read Contract**
2. Call `getWithdrawalRequest` with the owner address
3. If `syrupShares > 0`, there is a pending request
4. If `syrupShares == 0`, no pending request (either not requested or already claimed)

---

## Read-Only Functions

| Function | Description |
|---|---|
| `totalAssets()` | Total USDT managed by the vault |
| `balanceOf(address)` | Villa token balance |
| `convertToAssets(shares)` | Current USDT value of Villa shares |
| `convertToShares(assets)` | Villa shares for a given USDT amount |
| `previewDeposit(assets)` | Estimated shares for a deposit (after fee) |
| `previewMint(shares)` | USDT required to mint exact shares (including fee) |
| `highWaterMark()` | Current HWM for performance fee calculation |
| `maxDeposit(address)` | Maximum deposit allowed (respects pool cap) |
| `freeSyrupShares()` | Syrup shares not locked in withdrawal queue |
| `totalLockedSyrupShares()` | Syrup shares locked in pending withdrawals |

---

## Owner Functions

Only the contract owner can call:

| Function | Description |
|---|---|
| `setMaxPoolAmount(uint256)` | Set the maximum total assets cap |

---

## Deployment

### Environment Variables

```bash
export PRIVATE_KEY=0x...          # Deployer private key
export MAINNET_RPC_URL=https://...  # Mainnet RPC
export SEPOLIA_RPC_URL=https://...  # Sepolia RPC
export ETHERSCAN_API_KEY=...       # For verification
```

### Deploy to Sepolia

```bash
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

### Deploy to Mainnet

```bash
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv
```

---

## Testing

### Unit Tests (Mock Syrup)

```bash
forge test --match-contract VillaVaultTest -vv
```

### Mainnet Fork Tests (Real Syrup)

```bash
forge test --match-contract VillaVaultForkTest --fork-url $MAINNET_RPC_URL -vvv
```

### Coverage Report

```bash
forge coverage
```

---

## Security Notes

- The vault **never holds USDT** except transiently during deposit or in the withdrawal queue
- All fee parameters are **immutable** — no admin can change them after deployment
- There is **no pause function** and **no admin withdrawal** — funds are only accessible by depositors
- The contract uses OpenZeppelin v5 virtual shares/assets mechanism to protect against inflation attacks
- SafeERC20 is used for all USDT transfers
