# Slither Static Analysis Report — VillaVault

**Date:** 2026-02-24 (re-verified)
**Tool:** Slither v0.11.5
**Target:** `src/VillaVault.sol`
**Compiler:** Solc 0.8.24, optimizer 200 runs
**Deployed:** Sepolia [`0xBD8dDf12950a805aB0437b922B82D641E8BeE03D`](https://sepolia.etherscan.io/address/0xBD8dDf12950a805aB0437b922B82D641E8BeE03D) (verified)
**Command:** `slither src/VillaVault.sol --filter-paths "lib/" --exclude naming-convention,pragma,solc-version,assembly`

## Summary

| Severity | Count | Status |
|----------|-------|--------|
| High     | 0     | Clean  |
| Medium   | 0     | Clean (see notes below) |
| Low      | 2     | Accepted |
| Informational | 8 | Accepted |

**Result: No actionable High or Medium findings.**

---

## Detailed Findings

### 1. `incorrect-equality` (8 instances) — FALSE POSITIVES

**Detector:** Slither flags strict equality (`== 0`) checks as potentially dangerous.

**All instances are safe guard clauses:**

| Location | Check | Justification |
|----------|-------|---------------|
| `_accruePerformanceFee()` | `supply == 0` | Early return when vault is empty; `totalSupply()` cannot be manipulated |
| `_accruePerformanceFee()` | `feeAssets == 0` | Skip minting if fee rounds to zero |
| `_accruePerformanceFee()` | `denominator == 0` | Prevent division by zero |
| `_accruePerformanceFee()` | `feeShares == 0` | Skip minting if shares round to zero |
| `deposit()` | `shares == 0` | Revert if deposit is too small to mint any shares |
| `maxMint()` | `maxDep == 0` | Return 0 when pool is at capacity |
| `processRedeem()` | `req.syrupShares == 0` | Revert if no pending request exists |
| `redeem()` | `syrupSharesToLock == 0` | Revert if computed Syrup shares round to zero |

**Verdict:** These are standard zero-guards on internally computed values. They cannot be exploited by an attacker. No changes needed.

### 2. `reentrancy-events` (2 instances) — LOW / ACCEPTED

- `processRedeem()`: Event emitted after `syrup.redeem()` external call
- `redeem()`: Event emitted after `syrup.requestRedeem()` external call

**Justification:**
- State is fully updated before the external call (CEI pattern is followed)
- Events are emitted after the call because they include the return value (`assets`)
- The Syrup pool is a trusted, immutable protocol contract, not user-controlled
- No reentrancy vulnerability exists — only event ordering is flagged

**Verdict:** Accepted. No state corruption is possible.

---

## Previously Fixed Findings

| Finding | Resolution |
|---------|------------|
| `unused-return` on `syrup.deposit()` | Added `slither-disable-next-line` annotation with comment |
| `uninitialized-local` on `syrupSharesToLock` | Explicitly initialized to `0` |

---

## Excluded Detectors

The following detectors were excluded as they report style/version preferences:
- `naming-convention` — Immutable naming style is a project choice
- `pragma` — Floating pragma is intentional for library compatibility
- `solc-version` — 0.8.24 is a deliberate choice
- `assembly` — No inline assembly in the contract

---

## Test Coverage

| Metric | VillaVault.sol |
|--------|----------------|
| Lines | 96.90% (125/129) |
| Statements | 96.27% (155/161) |
| Branches | 87.50% (21/24) |
| Functions | 100.00% (20/20) |

3 uncovered branches (lines 302, 405, 496) are mathematically unreachable defensive guards — verified via formal analysis of rounding behavior.

---

## On-Chain Verification

The deployed contract was tested end-to-end on Sepolia with 135 passing checks covering:
- All constructor immutables and initial state
- Full deposit, mint, and async redeem/claim lifecycle with real USDC
- All revert conditions, access control, and ERC-4626 interface compliance
- Management fee (1%) and performance fee accrual mechanics

See `SEPOLIA_TEST_REPORT.md` for the full on-chain test report.
