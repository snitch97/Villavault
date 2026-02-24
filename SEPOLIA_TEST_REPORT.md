# VillaVault Sepolia On-Chain Test Report

**Date:** 2026-02-24
**Network:** Sepolia (Chain ID: 11155111)

| Contract | Address | Verified |
|----------|---------|----------|
| VillaVault | [`0xBD8dDf12950a805aB0437b922B82D641E8BeE03D`](https://sepolia.etherscan.io/address/0xBD8dDf12950a805aB0437b922B82D641E8BeE03D) | Yes |
| MockSyrup | [`0xEcF55D28372a631dcD507ee348a8b106d86630D0`](https://sepolia.etherscan.io/address/0xEcF55D28372a631dcD507ee348a8b106d86630D0) | Yes |

**Deployer/Owner:** `0xdEFd43800846f91e34De43F18b3Bbe82e1791ecd`
**Underlying Asset:** Circle USDC on Sepolia (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`)

---

## Summary

| # | Test Category | Pass | Fail |
|---|---------------|------|------|
| 1 | Constructor Immutables | 13 | 0 |
| 2 | Empty Vault State | 8 | 0 |
| 3 | Preview Functions | 6 | 0 |
| 4 | Revert Conditions | 5 | 0 |
| 5 | Owner Functions + Access Control | 5 | 0 |
| 6 | Performance Fee (empty vault) | 2 | 0 |
| 7 | **Live Deposit Flow (end-to-end)** | 11 | 0 |
| 8 | **Live Mint Flow (end-to-end)** | 5 | 0 |
| 9 | **Async Redeem + ProcessRedeem Flow** | 10 | 0 |
| 10 | Etherscan Verification | 2 | 0 |
| 11 | Post-Transaction State | 8 | 0 |
| — | Unit Tests (local, mocked) | 60 | 0 |
| | **TOTAL** | **135** | **0** |

---

## Test 1: Constructor Immutables (13/13)

| Function | Expected | Actual | Result |
|----------|----------|--------|--------|
| `syrup()` | `0xEcF55D28...` | `0xEcF55D28...` | PASS |
| `asset()` | `0x1c7D4B19...` (USDC) | `0x1c7D4B19...` | PASS |
| `usdt()` | `0x1c7D4B19...` | `0x1c7D4B19...` | PASS |
| `feeRecipient()` | `0x6AfDD1Da...` | `0x6AfDD1Da...` | PASS |
| `owner()` | `0xdEFd4380...` | `0xdEFd4380...` | PASS |
| `managementFeeBP()` | 100 (1%) | 100 | PASS |
| `performanceFeeBP()` | 500 (5%) | 500 | PASS |
| `maxPoolAmount()` | 10,000,000,000,000 | 10,000,000,000,000 | PASS |
| `highWaterMark()` | 1e18 | 1e18 | PASS |
| `decimals()` | 6 | 6 | PASS |
| `BP()` | 10,000 | 10,000 | PASS |
| `name()` | "Villa Token" | "Villa Token" | PASS |
| `symbol()` | "Villa" | "Villa" | PASS |

---

## Test 2: Empty Vault State (8/8)

All zero-state checks pass: `totalAssets`, `totalSupply`, `totalLockedSyrupShares`, `freeSyrupShares`, `maxWithdraw`, `maxRedeem`, `balanceOf` = 0. `maxDeposit` = maxPoolAmount.

---

## Test 3: Preview Functions (6/6)

| Function | Input | Expected | Actual | Result |
|----------|-------|----------|--------|--------|
| `previewDeposit()` | 10 USDC | 9,900,000 (1% fee) | 9,900,000 | PASS |
| `previewMint()` | 9.9M shares | 10,000,000 | 10,000,000 | PASS |
| `previewWithdraw()` | 1 USDC | 0 (async) | 0 | PASS |
| `previewRedeem()` | 1M shares | 1,000,000 | 1,000,000 | PASS |
| `convertToShares()` | 1 USDC | 1,000,000 | 1,000,000 | PASS |
| `convertToAssets()` | 1M shares | 1,000,000 | 1,000,000 | PASS |

---

## Test 4: Revert Conditions (5/5)

| Call | Expected Error | Result |
|------|----------------|--------|
| `deposit(0, deployer)` | `ZeroAmount()` | PASS |
| `mint(0, deployer)` | `ZeroAmount()` | PASS |
| `redeem(0, deployer, deployer)` | `ZeroAmount()` | PASS |
| `withdraw(1e6, deployer, deployer)` | `AsyncWithdrawalsOnly()` | PASS |
| `processRedeem(deployer)` | `NoPendingRequest()` | PASS |

---

## Test 5: Owner Functions + Access Control (5/5)

| Action | Result |
|--------|--------|
| `setMaxPoolAmount(20M)` — tx succeeds | PASS |
| Read `maxPoolAmount()` = 20M | PASS |
| `setMaxPoolAmount(10M)` — restore | PASS |
| Read `maxPoolAmount()` = 10M | PASS |
| Non-owner `setMaxPoolAmount()` reverts | PASS |

---

## Test 6: Performance Fee on Empty Vault (2/2)

| Action | Result |
|--------|--------|
| `accruePerformanceFee()` succeeds (no-op) | PASS |
| `highWaterMark()` unchanged at 1e18 | PASS |

---

## Test 7: Live Deposit Flow (11/11)

**Deposit: 10 USDC (10,000,000 units)**

| Check | Expected | Actual | Result |
|-------|----------|--------|--------|
| USDC.approve() | success | success | PASS |
| deposit() tx | success | success | PASS |
| Villa shares received | > 0 | 9,900,000 | PASS |
| Shares = net deposit | 9,900,000 | 9,900,000 | PASS |
| Management fee to recipient | 100,000 (1%) | 100,000 | PASS |
| USDC spent by deployer | 10,000,000 | 10,000,000 | PASS |
| Vault USDC balance | 0 (swept to Syrup) | 0 | PASS |
| Vault Syrup shares | > 0 | 9,900,000 | PASS |
| totalAssets | > 0 | 9,900,000 | PASS |
| totalSupply = shares | 9,900,000 | 9,900,000 | PASS |
| freeSyrupShares = Syrup balance | 9,900,000 | 9,900,000 | PASS |

Tx: [`0xf6c6aedb...`](https://sepolia.etherscan.io/tx/0xf6c6aedb5b0d945b9304261e86e08e91eadb8b554bbde75fca147f0675693d53)

---

## Test 8: Live Mint Flow (5/5)

**Mint: 4,950,000 Villa shares**

| Check | Expected | Actual | Result |
|-------|----------|--------|--------|
| USDC.approve() | success | success | PASS |
| mint() tx | success | success | PASS |
| Exact shares received | 4,950,000 | 4,950,000 | PASS |
| Gross USDC spent | 5,000,000 | 5,000,000 | PASS |
| Management fee | 50,000 (1%) | 50,000 | PASS |

---

## Test 9: Async Redeem + ProcessRedeem Flow (10/10)

**Redeem: 7,425,000 Villa shares (half of balance)**

| Check | Expected | Actual | Result |
|-------|----------|--------|--------|
| redeem() tx | success | success | PASS |
| Villa shares burned | 7,425,000 remaining | 7,425,000 | PASS |
| Pending request syrupShares | > 0 | 7,425,000 | PASS |
| Pending request villaShares | 7,425,000 | 7,425,000 | PASS |
| totalLockedSyrupShares | > 0 | 7,425,000 | PASS |
| Double redeem reverts | RequestAlreadyPending | reverted | PASS |
| MockSyrup.processRequest() | success | success | PASS |
| processRedeem() tx | success | success | PASS |
| USDC received | > 0 | 7,425,000 | PASS |
| Withdrawal request cleared | syrupShares = 0 | 0 | PASS |

---

## Test 10: Etherscan Verification (2/2)

| Contract | Verified | Compiler |
|----------|----------|----------|
| VillaVault | Yes | v0.8.24+commit.e11b9ed9 |
| MockSyrup | Yes | v0.8.24+commit.e11b9ed9 |

---

## Test 11: Post-Transaction State (8/8)

| Check | Value | Result |
|-------|-------|--------|
| totalAssets | 7,425,000 | PASS |
| totalSupply | 7,425,000 | PASS |
| totalLockedSyrupShares | 0 (after claim) | PASS |
| freeSyrupShares | 7,425,000 | PASS |
| Deployer owns all shares | 7,425,000 = totalSupply | PASS |
| HWM | 1e18 (no yield above HWM) | PASS |
| maxDeposit | 9,999,992,575,000 (cap - totalAssets) | PASS |
| previewRedeem(all shares) | 7,425,000 USDC | PASS |

---

## Unit Test Suite (Local, Mocked)

```
60 passed, 0 failed, 0 skipped
```

### Coverage (VillaVault.sol)

| Metric | Coverage |
|--------|----------|
| Lines | 96.90% (125/129) |
| Statements | 96.27% (155/161) |
| Branches | 87.50% (21/24) |
| Functions | 100.00% (20/20) |

---

## Deployment Note

The Maple Syrup pool on Sepolia (`0x3EB612858EE843eBb14Df37b9Ec2c7c82B23eE2B`) is a private, permissioned USDC pool that does not allow arbitrary depositors. To enable full end-to-end testing, a MockSyrup contract was deployed alongside VillaVault. Both contracts use Circle's Sepolia USDC (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`) as the underlying asset.

The VillaVault contract code is identical across all deployments — no source modifications were made. Only the constructor arguments differ (Syrup pool address).

---

## Conclusion

**135 / 135 tests passed.** Every contract function has been tested on-chain on Sepolia, including the full deposit, mint, and async redeem/claim lifecycle with real USDC tokens and live transactions.
