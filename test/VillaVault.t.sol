// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VillaVault} from "../src/VillaVault.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockSyrup} from "./mocks/MockSyrup.sol";

/// @title VillaVaultTest
/// @notice Comprehensive unit tests for VillaVault covering deposits, mints, fees, HWM,
///         async withdrawals, totalAssets, edge cases, and access control.
contract VillaVaultTest is Test {
    using Math for uint256;

    VillaVault public vault;
    MockUSDT public usdt;
    MockSyrup public syrup;

    address public owner = makeAddr("owner");
    address public feeRecipient = 0x6AfDD1DaD70708230aC27620775df9897938a76D;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant MANAGEMENT_FEE_BP = 100;  // 1%
    uint256 public constant PERFORMANCE_FEE_BP = 500; // 5%
    uint256 public constant BP = 10_000;
    uint256 public constant MAX_POOL = 1_000_000e6;   // 1M USDT

    function setUp() public {
        usdt = new MockUSDT();
        syrup = new MockSyrup(address(usdt));

        vault = new VillaVault(
            address(usdt),
            address(syrup),
            feeRecipient,
            MANAGEMENT_FEE_BP,
            PERFORMANCE_FEE_BP,
            MAX_POOL,
            owner
        );

        // Fund test users.
        usdt.mint(alice, 100_000e6);
        usdt.mint(bob, 100_000e6);

        // Approvals.
        vm.prank(alice);
        usdt.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdt.approve(address(vault), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor / Deployment
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public view {
        assertEq(address(vault.syrup()), address(syrup));
        assertEq(address(vault.usdt()), address(usdt));
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.managementFeeBP(), MANAGEMENT_FEE_BP);
        assertEq(vault.performanceFeeBP(), PERFORMANCE_FEE_BP);
        assertEq(vault.maxPoolAmount(), MAX_POOL);
        assertEq(vault.owner(), owner);
        assertEq(vault.highWaterMark(), 1e18);
        assertEq(vault.decimals(), 6);
        assertEq(vault.asset(), address(usdt));
    }

    function test_constructor_revertsZeroSyrup() public {
        vm.expectRevert(VillaVault.ZeroSyrupAddress.selector);
        new VillaVault(address(usdt), address(0), feeRecipient, 100, 500, MAX_POOL, owner);
    }

    function test_constructor_revertsZeroFeeRecipient() public {
        vm.expectRevert(VillaVault.ZeroFeeRecipient.selector);
        new VillaVault(address(usdt), address(syrup), address(0), 100, 500, MAX_POOL, owner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Owner: setMaxPoolAmount
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setMaxPoolAmount_owner() public {
        vm.prank(owner);
        vault.setMaxPoolAmount(2_000_000e6);
        assertEq(vault.maxPoolAmount(), 2_000_000e6);
    }

    function test_setMaxPoolAmount_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxPoolAmount(2_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Deposit
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deposit_basic() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Management fee = 1% of 10_000 = 100 USDT
        uint256 fee = 100e6;
        uint256 netDeposit = depositAmount - fee;

        // Fee recipient should have received USDT.
        assertEq(usdt.balanceOf(feeRecipient), fee);

        // Alice should have Villa shares.
        assertEq(vault.balanceOf(alice), shares);
        assertTrue(shares > 0);

        // Vault should have 0 USDT (all swept to Syrup).
        assertEq(usdt.balanceOf(address(vault)), 0);

        // Syrup should hold the Syrup shares for the vault.
        assertTrue(syrup.balanceOf(address(vault)) > 0);

        // Net deposit went to Syrup.
        assertEq(usdt.balanceOf(address(syrup)), netDeposit);
    }

    function test_deposit_sharesCalculation_1to1() public {
        // At 1:1 exchange rate, net deposit = shares (with virtual offset).
        uint256 depositAmount = 10_000e6;
        uint256 fee = depositAmount * MANAGEMENT_FEE_BP / BP; // 100e6
        uint256 netAssets = depositAmount - fee; // 9900e6

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // With virtual shares (OZ uses +1 virtual asset, +1 virtual share for offset=0),
        // first depositor: shares = netAssets * (0 + 1) / (0 + 1) = netAssets
        assertEq(shares, netAssets);
    }

    function test_deposit_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert(VillaVault.ZeroAmount.selector);
        vault.deposit(0, alice);
    }

    function test_deposit_revertsExceedsMaxPool() public {
        vm.prank(owner);
        vault.setMaxPoolAmount(1_000e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(2_000e6, alice);
    }

    function test_deposit_multipleUsers() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(10_000e6, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(10_000e6, bob);

        // Both deposits have same amount so should receive similar shares
        // (second deposit sees the already-deposited totalAssets but same rate).
        assertEq(vault.balanceOf(alice), aliceShares);
        assertEq(vault.balanceOf(bob), bobShares);
        // Shares should be approximately equal (within virtual offset rounding).
        assertApproxEqAbs(aliceShares, bobShares, 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Mint
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mint_basic() public {
        uint256 desiredShares = 5_000e6;

        vm.prank(alice);
        uint256 assets = vault.mint(desiredShares, alice);

        assertEq(vault.balanceOf(alice), desiredShares);
        assertTrue(assets > desiredShares); // gross > net because of 1% fee
    }

    function test_mint_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert(VillaVault.ZeroAmount.selector);
        vault.mint(0, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Management Fee
    // ═══════════════════════════════════════════════════════════════════════════

    function test_managementFee_exactAmount() public {
        uint256 depositAmount = 50_000e6;
        uint256 expectedFee = depositAmount * MANAGEMENT_FEE_BP / BP; // 500e6

        uint256 recipientBefore = usdt.balanceOf(feeRecipient);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 recipientAfter = usdt.balanceOf(feeRecipient);
        // Fee should be exactly 1% rounded up at most 1 wei.
        assertApproxEqAbs(recipientAfter - recipientBefore, expectedFee, 1);
    }

    function test_managementFee_smallDeposit() public {
        // 100 USDT → 1 USDT fee
        vm.prank(alice);
        vault.deposit(100e6, alice);

        assertEq(usdt.balanceOf(feeRecipient), 1e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Performance Fee & HWM
    // ═══════════════════════════════════════════════════════════════════════════

    function test_performanceFee_noFeeWithoutProfit() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

        // Accrue with no profit.
        vault.accruePerformanceFee();

        assertEq(vault.balanceOf(feeRecipient), feeRecipientSharesBefore);
    }

    function test_performanceFee_accruesOnProfit() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

        // Simulate 5% yield by increasing Syrup exchange rate.
        syrup.setExchangeRate(1.05e18);

        vault.accruePerformanceFee();

        uint256 feeRecipientSharesAfter = vault.balanceOf(feeRecipient);
        assertTrue(feeRecipientSharesAfter > feeRecipientSharesBefore, "Fee shares should be minted");
    }

    function test_performanceFee_hwmUpdated() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 hwmBefore = vault.highWaterMark();

        // 10% yield.
        syrup.setExchangeRate(1.10e18);
        vault.accruePerformanceFee();

        uint256 hwmAfter = vault.highWaterMark();
        assertTrue(hwmAfter > hwmBefore, "HWM should increase");
    }

    function test_performanceFee_noDoubleFeeOnSameProfit() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // 5% yield.
        syrup.setExchangeRate(1.05e18);
        vault.accruePerformanceFee();

        uint256 feeSharesAfterFirst = vault.balanceOf(feeRecipient);

        // Accrue again without additional profit — no new fees.
        vault.accruePerformanceFee();
        assertEq(vault.balanceOf(feeRecipient), feeSharesAfterFirst);
    }

    function test_performanceFee_onlyAboveHWM() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // 10% yield.
        syrup.setExchangeRate(1.10e18);
        vault.accruePerformanceFee();
        uint256 hwmAfterFirst = vault.highWaterMark();

        // Drop to 5% above original (below current HWM). No fee.
        syrup.setExchangeRate(1.05e18);
        vault.accruePerformanceFee();
        assertEq(vault.highWaterMark(), hwmAfterFirst, "HWM should not decrease");

        // Rise to 15% above original (above HWM). Fee only on difference.
        syrup.setExchangeRate(1.15e18);
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        vault.accruePerformanceFee();
        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertTrue(feeSharesAfter > feeSharesBefore, "Should accrue fee for new profit above HWM");
    }

    function test_performanceFee_fivePercentOfProfit() public {
        // Alice deposits 10,000 USDT (net 9,900 after 1% management fee).
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 assetsBefore = vault.totalAssets();

        // 10% yield.
        syrup.setExchangeRate(1.10e18);
        uint256 assetsAfterYield = vault.totalAssets();
        uint256 totalProfit = assetsAfterYield - assetsBefore;

        vault.accruePerformanceFee();

        uint256 feeShares = vault.balanceOf(feeRecipient);
        // The fee shares, when converted to assets, should be ~5% of the total profit.
        uint256 feeAssetValue = vault.convertToAssets(feeShares);

        uint256 expectedFeeAssets = totalProfit * PERFORMANCE_FEE_BP / BP;

        // Allow small rounding tolerance (within 2 USDT for 6-decimal token).
        assertApproxEqAbs(feeAssetValue, expectedFeeAssets, 2e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // totalAssets
    // ═══════════════════════════════════════════════════════════════════════════

    function test_totalAssets_initiallyZero() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_totalAssets_afterDeposit() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Net deposit = 9,900 USDT in Syrup at 1:1 rate.
        assertEq(vault.totalAssets(), 9_900e6);
    }

    function test_totalAssets_reflectsYield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // 10% yield.
        syrup.setExchangeRate(1.10e18);

        // totalAssets should be ~9,900 * 1.10 = 10,890 USDT.
        assertEq(vault.totalAssets(), 10_890e6);
    }

    function test_totalAssets_includesLockedShares() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        // Request redeem half.
        vm.prank(alice);
        vault.redeem(aliceShares / 2, alice, alice);

        // totalAssets should still reflect the locked shares.
        // Some rounding is acceptable.
        assertApproxEqAbs(vault.totalAssets(), 9_900e6, 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Async Withdrawal — Request
    // ═══════════════════════════════════════════════════════════════════════════

    function test_redeem_requestCreated() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(aliceShares, alice, alice);

        // Returns 0 assets (async).
        assertEq(assets, 0);

        // Villa shares are burned.
        assertEq(vault.balanceOf(alice), 0);

        // Pending request exists.
        (uint256 syrupSh, uint256 villaSh, address receiver) = vault.getWithdrawalRequest(alice);
        assertTrue(syrupSh > 0);
        assertEq(villaSh, aliceShares);
        assertEq(receiver, alice);
    }

    function test_redeem_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert(VillaVault.ZeroAmount.selector);
        vault.redeem(0, alice, alice);
    }

    function test_redeem_revertsDoublePending() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 half = vault.balanceOf(alice) / 2;

        vm.prank(alice);
        vault.redeem(half, alice, alice);

        // Second request should revert.
        vm.prank(alice);
        vm.expectRevert(VillaVault.RequestAlreadyPending.selector);
        vault.redeem(half, alice, alice);
    }

    function test_redeem_withAllowance() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        // Alice approves Bob to spend her shares.
        vm.prank(alice);
        vault.approve(bob, aliceShares);

        // Bob initiates redeem on behalf of Alice.
        vm.prank(bob);
        vault.redeem(aliceShares, bob, alice);

        assertEq(vault.balanceOf(alice), 0);
        (uint256 syrupSh,,) = vault.getWithdrawalRequest(alice);
        assertTrue(syrupSh > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Async Withdrawal — Process (Claim)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_processRedeem_basic() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceUsdtBefore = usdt.balanceOf(alice);

        // Request full redeem.
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        // Process the request in Maple mock.
        syrup.processRequest(address(vault));

        // Claim.
        uint256 assets = vault.processRedeem(alice);

        assertTrue(assets > 0, "Should receive USDT");
        assertEq(usdt.balanceOf(alice), aliceUsdtBefore + assets);

        // Request should be cleared.
        (uint256 syrupSh,,) = vault.getWithdrawalRequest(alice);
        assertEq(syrupSh, 0);
    }

    function test_processRedeem_revertsNoPending() public {
        vm.expectRevert(VillaVault.NoPendingRequest.selector);
        vault.processRedeem(alice);
    }

    function test_processRedeem_differentReceiver() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        // Alice requests, Bob receives.
        vm.prank(alice);
        vault.redeem(aliceShares, bob, alice);

        syrup.processRequest(address(vault));
        uint256 bobBefore = usdt.balanceOf(bob);
        vault.processRedeem(alice);

        assertTrue(usdt.balanceOf(bob) > bobBefore, "Bob should receive USDT");
    }

    function test_processRedeem_afterYield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        // 10% yield before request.
        syrup.setExchangeRate(1.10e18);

        // Fund the mock pool to back the extra USDT.
        usdt.mint(address(this), 10_000e6);
        usdt.approve(address(syrup), 10_000e6);
        syrup.fundPool(10_000e6);

        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        syrup.processRequest(address(vault));

        uint256 aliceBefore = usdt.balanceOf(alice);
        vault.processRedeem(alice);
        uint256 received = usdt.balanceOf(alice) - aliceBefore;

        // Should receive more than the net deposit (9,900) due to yield, minus perf fee dilution.
        assertTrue(received > 9_900e6, "Should receive more than net deposit due to yield");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Withdraw (always reverts)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdraw_alwaysReverts() public {
        vm.prank(alice);
        vm.expectRevert(VillaVault.AsyncWithdrawalsOnly.selector);
        vault.withdraw(100e6, alice, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // maxDeposit / maxMint / maxWithdraw / maxRedeem
    // ═══════════════════════════════════════════════════════════════════════════

    function test_maxDeposit_respectsCap() public {
        assertEq(vault.maxDeposit(alice), MAX_POOL);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Net 9,900 in Syrup => maxDeposit should be MAX_POOL - 9,900.
        assertEq(vault.maxDeposit(alice), MAX_POOL - 9_900e6);
    }

    function test_maxDeposit_zeroWhenFull() public {
        // Set a cap, fill it via yield appreciation, verify maxDeposit returns 0.
        vm.prank(owner);
        vault.setMaxPoolAmount(10_000e6);

        vm.prank(alice);
        vault.deposit(10_000e6, alice); // nets 9,900 → maxDeposit = 100

        // Simulate yield that pushes totalAssets above the cap.
        syrup.setExchangeRate(1.02e18); // ~2% yield → totalAssets ≈ 10,098

        assertEq(vault.maxDeposit(alice), 0, "Pool should be at capacity after yield");
    }

    function test_maxWithdraw_alwaysZero() public view {
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxRedeem_alwaysZero() public view {
        assertEq(vault.maxRedeem(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Preview functions
    // ═══════════════════════════════════════════════════════════════════════════

    function test_previewDeposit_accountsForFee() public view {
        uint256 assets = 10_000e6;
        uint256 shares = vault.previewDeposit(assets);

        // Fee = 100e6, net = 9_900e6. At 1:1, shares ≈ 9_900e6 (with virtual offset).
        assertEq(shares, 9_900e6);
    }

    function test_previewMint_includesFee() public view {
        uint256 shares = 9_900e6;
        uint256 assets = vault.previewMint(shares);

        // net = 9_900, gross = 9_900 * 10000 / 9900 = 10_000.
        assertEq(assets, 10_000e6);
    }

    function test_previewWithdraw_alwaysZero() public view {
        assertEq(vault.previewWithdraw(1_000e6), 0);
    }

    function test_previewRedeem_returnsEstimate() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 shares = vault.balanceOf(alice);
        uint256 est = vault.previewRedeem(shares);

        // Should be approximately the net deposit.
        assertApproxEqAbs(est, 9_900e6, 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deposit_tinyAmount() public {
        // 1 USDT = 1e6 smallest units. Fee = 1e6 * 100 / 10000 = 10000. Net = 990000.
        usdt.mint(alice, 1e6);
        vm.prank(alice);
        uint256 shares = vault.deposit(1e6, alice);
        assertTrue(shares > 0);
    }

    function test_multipleDepositsAndRedeems() public {
        // Alice deposits.
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Bob deposits.
        vm.prank(bob);
        vault.deposit(20_000e6, bob);

        // Alice redeems.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        syrup.processRequest(address(vault));

        uint256 aliceBefore = usdt.balanceOf(alice);
        vault.processRedeem(alice);
        uint256 aliceReceived = usdt.balanceOf(alice) - aliceBefore;

        // Alice should receive approximately her net deposit.
        assertApproxEqAbs(aliceReceived, 9_900e6, 2);

        // Bob's shares are still there.
        assertTrue(vault.balanceOf(bob) > 0);
    }

    function test_performanceFee_beforeDeposit() public {
        // Alice deposits.
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Yield accrues.
        syrup.setExchangeRate(1.05e18);

        // Bob deposits — performance fee should be accrued first.
        vm.prank(bob);
        vault.deposit(10_000e6, bob);

        // Fee recipient should have shares from performance fee.
        assertTrue(vault.balanceOf(feeRecipient) > 0);
    }

    function test_performanceFee_beforeRedeem() public {
        // Alice deposits.
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Yield accrues.
        syrup.setExchangeRate(1.05e18);

        uint256 aliceShares = vault.balanceOf(alice);

        // Alice redeems — performance fee should be accrued first.
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertTrue(vault.balanceOf(feeRecipient) > 0);
    }

    function test_freeSyrupShares() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 free = vault.freeSyrupShares();
        assertTrue(free > 0);

        // After redeem, free should decrease.
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeem(half, alice, alice);

        assertTrue(vault.freeSyrupShares() < free);
    }

    function test_totalLockedSyrupShares_tracking() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        assertEq(vault.totalLockedSyrupShares(), 0);

        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeem(half, alice, alice);

        assertTrue(vault.totalLockedSyrupShares() > 0);

        // Process and claim.
        syrup.processRequest(address(vault));
        vault.processRedeem(alice);

        assertEq(vault.totalLockedSyrupShares(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fuzz tests
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_deposit_alwaysDeductsFee(uint256 amount) public {
        // Bound to reasonable range: 100 USDT to 500k USDT.
        amount = bound(amount, 100e6, 500_000e6);

        usdt.mint(alice, amount);
        vm.prank(alice);
        usdt.approve(address(vault), amount);

        uint256 recipientBefore = usdt.balanceOf(feeRecipient);

        vm.prank(alice);
        vault.deposit(amount, alice);

        uint256 recipientAfter = usdt.balanceOf(feeRecipient);
        uint256 expectedFee = (amount * MANAGEMENT_FEE_BP + BP - 1) / BP; // ceil division

        assertApproxEqAbs(recipientAfter - recipientBefore, expectedFee, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Branch coverage — Performance fee edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_accruePerformanceFee_emptyVault() public {
        // supply == 0 early return (line 474).
        vault.accruePerformanceFee();
        // No revert, no shares minted.
        assertEq(vault.balanceOf(feeRecipient), 0);
    }

    function test_accruePerformanceFee_tinyProfitRoundsToZeroFee() public {
        // Hit line 491: feeAssets == 0. Deposit small amount, then create a tiny
        // profit where profitPerShare > 0 (pass line 480) but totalProfit * perfFeeBP / BP == 0.
        vm.prank(alice);
        vault.deposit(1e6, alice); // net = 990_000, supply = 990_000

        // Donate 1 unit of USDT directly to vault. This increases totalAssets by 1
        // without changing supply, creating a tiny profit above HWM.
        // totalProfit = profitPerShare * supply / 1e18.
        // profitPerShare ≈ 1e18 / 990_000 ≈ 1.01e12, very small.
        // totalProfit ≈ 1.01e12 * 990_000 / 1e18 ≈ 0 (rounds to 0).
        // feeAssets = 0 * 500 / 10000 = 0 → return at line 491.
        usdt.mint(address(vault), 1);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        vault.accruePerformanceFee();

        // feeAssets was 0, so no shares minted.
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore);
    }

    function test_accruePerformanceFee_feeSharesRoundToZero() public {
        // Hit line 500: feeShares == 0. We need feeAssets > 0 but
        // feeShares = supply * feeAssets / (assets_ - feeAssets) rounds to 0.
        // This requires supply * feeAssets < (assets_ - feeAssets), i.e., supply << assets_.
        // After significant yield, totalAssets >> supply (assets grow, supply unchanged).
        vm.prank(alice);
        vault.deposit(10_000e6, alice); // supply = 9900e6, totalAssets = 9900e6

        // First: create large yield and accrue fee to move HWM up.
        syrup.setExchangeRate(10e18); // 10x yield
        vault.accruePerformanceFee();

        // Now totalAssets ≈ 99_000e6, supply ≈ 9900e6 + feeShares (small bump).
        // HWM is updated to new level. Now create a tiny profit above new HWM.
        // Donate a small amount of USDT directly to the vault.
        // feeAssets will be tiny, and supply * feeAssets < (assets_ - feeAssets) → feeShares = 0.
        usdt.mint(address(vault), 200);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        vault.accruePerformanceFee();
        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);

        // feeShares rounded to 0.
        assertEq(feeSharesAfter, feeSharesBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Branch coverage — Deposit/Mint limits
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mint_revertsExceedsMaxPool() public {
        // Set a low cap and try to mint more shares than allowed.
        vm.prank(owner);
        vault.setMaxPoolAmount(1_000e6);

        // Minting 5000e6 shares requires ~5050 USDT gross, exceeds 1000 cap.
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(5_000e6, alice);
    }

    function test_deposit_feeIsZeroForZeroFeeVault() public {
        // Deploy a vault with 0 management fee to hit the fee==0 branch (line 308).
        VillaVault zeroFeeVault = new VillaVault(
            address(usdt),
            address(syrup),
            feeRecipient,
            0,  // 0 management fee
            PERFORMANCE_FEE_BP,
            MAX_POOL,
            owner
        );

        usdt.mint(alice, 10_000e6);
        vm.prank(alice);
        usdt.approve(address(zeroFeeVault), type(uint256).max);

        vm.prank(alice);
        uint256 shares = zeroFeeVault.deposit(10_000e6, alice);

        // No fee sent to recipient.
        assertEq(usdt.balanceOf(feeRecipient), 0);
        // All assets become shares (1:1 first deposit).
        assertEq(shares, 10_000e6);
    }

    function test_maxMint_respectsCap() public {
        // After a deposit, maxMint should reflect remaining capacity.
        vm.prank(alice);
        vault.deposit(10_000e6, alice); // nets 9,900

        uint256 maxSh = vault.maxMint(alice);
        // maxDeposit = MAX_POOL - 9_900e6. maxMint = convertToShares(maxDeposit).
        uint256 maxDep = vault.maxDeposit(alice);
        assertTrue(maxSh > 0);
        assertTrue(maxSh <= maxDep); // at 1:1 rate, shares <= assets
    }

    function test_maxMint_zeroWhenFull() public {
        vm.prank(owner);
        vault.setMaxPoolAmount(10_000e6);

        vm.prank(alice);
        vault.deposit(10_000e6, alice); // nets 9,900

        // Push over cap with yield.
        syrup.setExchangeRate(1.02e18);

        assertEq(vault.maxMint(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Branch coverage — Redeem edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_redeem_syrupSharesToLockCapped() public {
        // Scenario: proportional calculation > totalSyrup (line 405).
        // This can happen when USDT balance in vault inflates totalAssets but
        // totalSyrup is relatively small.
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        // Donate USDT directly to the vault to inflate totalAssets without increasing syrup.
        usdt.mint(address(vault), 50_000e6);

        // Now totalAssets >> syrup value, so villaAssets could be > what syrup can cover.
        // totalSyrup.mulDiv(villaAssets, totalVal) could exceed totalSyrup.
        // Actually with floor rounding it won't exceed, but let's still test the path.
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        // Should not revert; syrupSharesToLock is capped.
        (uint256 syrupSh,,) = vault.getWithdrawalRequest(alice);
        assertTrue(syrupSh > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Branch coverage — ProcessRedeem edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_processRedeem_zeroAssetsFromSyrup() public {
        // When syrup.redeem() returns 0, the vault should not attempt a transfer.
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        syrup.processRequest(address(vault));

        // Force syrup to return 0 on redeem.
        syrup.setForceZeroRedeem(true);

        uint256 aliceBefore = usdt.balanceOf(alice);
        uint256 assets = vault.processRedeem(alice);

        assertEq(assets, 0);
        assertEq(usdt.balanceOf(alice), aliceBefore); // No USDT transferred.
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Branch coverage — Mint fee branch
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mint_feeIsZeroForZeroFeeVault() public {
        // Deploy a vault with 0 management fee to hit fee==0 branch in mint (line 348).
        VillaVault zeroFeeVault = new VillaVault(
            address(usdt),
            address(syrup),
            feeRecipient,
            0,  // 0 management fee
            PERFORMANCE_FEE_BP,
            MAX_POOL,
            owner
        );

        usdt.mint(alice, 10_000e6);
        vm.prank(alice);
        usdt.approve(address(zeroFeeVault), type(uint256).max);

        uint256 recipientBefore = usdt.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 assets = zeroFeeVault.mint(5_000e6, alice);

        assertEq(zeroFeeVault.balanceOf(alice), 5_000e6);
        assertEq(usdt.balanceOf(feeRecipient), recipientBefore); // No fee.
        assertEq(assets, 5_000e6); // gross == net when fee is 0.
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Branch coverage — denominator == 0 in performance fee
    // ═══════════════════════════════════════════════════════════════════════════

    function test_redeem_revertsSyrupSharesToLockZero() public {
        // Hit line 410: syrupSharesToLock == 0 → revert ZeroAmount.
        // After Syrup rate drops, totalAssets < totalSupply. Then _convertToAssets(1 share)
        // rounds to 0, making syrupSharesToLock = 0.
        vm.prank(alice);
        vault.deposit(10_000e6, alice); // supply = 9900e6, totalAssets = 9900e6

        // Drop Syrup rate below 1:1 so totalAssets < supply.
        syrup.setExchangeRate(0.5e18);
        // totalAssets = convertToAssets(9900e6) = 4950e6. supply = 9900e6.

        // Mint 1 share to bob (requires tiny USDT).
        usdt.mint(bob, 100e6);
        vm.prank(bob);
        usdt.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vault.mint(1, bob);

        // bob tries to redeem 1 share. villaAssets = _convertToAssets(1, Floor) = 0.
        // syrupSharesToLock = totalSyrup * 0 / totalVal = 0 → revert ZeroAmount.
        vm.prank(bob);
        vm.expectRevert(VillaVault.ZeroAmount.selector);
        vault.redeem(1, bob, bob);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fuzz tests
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_previewDeposit_matchesActual(uint256 amount) public {
        amount = bound(amount, 100e6, 500_000e6);

        uint256 previewShares = vault.previewDeposit(amount);

        usdt.mint(alice, amount);
        vm.prank(alice);
        usdt.approve(address(vault), amount);

        vm.prank(alice);
        uint256 actualShares = vault.deposit(amount, alice);

        assertEq(actualShares, previewShares);
    }
}
