// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VillaVault} from "../src/VillaVault.sol";
import {ISyrup} from "../src/interfaces/ISyrup.sol";

/// @title VillaVaultForkTest
/// @notice Integration tests running on a mainnet fork to validate real Syrup interaction.
/// @dev Requires MAINNET_RPC_URL env variable. Run with:
///      forge test --match-contract VillaVaultForkTest --fork-url $MAINNET_RPC_URL -vvv
contract VillaVaultForkTest is Test {
    VillaVault public vault;

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant SYRUP_POOL = 0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;
    address constant FEE_RECIPIENT = 0x6AfDD1DaD70708230aC27620775df9897938a76D;

    // Whale address with substantial USDT balance for testing.
    address constant USDT_WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

    address public deployer = makeAddr("deployer");
    address public alice = makeAddr("alice");

    uint256 constant MANAGEMENT_FEE_BP = 100;
    uint256 constant PERFORMANCE_FEE_BP = 500;
    uint256 constant MAX_POOL = 100_000_000e6; // 100M cap

    function setUp() public {
        // Only run if fork URL is available.
        // Fork tests are expected to run with --fork-url flag.
        vault = new VillaVault(
            USDT,
            SYRUP_POOL,
            FEE_RECIPIENT,
            MANAGEMENT_FEE_BP,
            PERFORMANCE_FEE_BP,
            MAX_POOL,
            deployer
        );

        // Fund alice from the whale.
        vm.prank(USDT_WHALE);
        IERC20(USDT).transfer(alice, 100_000e6);

        vm.prank(alice);
        IERC20(USDT).approve(address(vault), type(uint256).max);
    }

    function test_fork_deposit() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        assertTrue(shares > 0, "Should receive Villa shares");
        assertEq(vault.balanceOf(alice), shares);

        // Fee recipient got 1%.
        assertEq(IERC20(USDT).balanceOf(FEE_RECIPIENT), 100e6);

        // Vault has no USDT (all swept to Syrup).
        assertEq(IERC20(USDT).balanceOf(address(vault)), 0);

        // Syrup balance exists.
        assertTrue(ISyrup(SYRUP_POOL).balanceOf(address(vault)) > 0);
    }

    function test_fork_totalAssets_matchesSyrupValue() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        uint256 ta = vault.totalAssets();
        uint256 syrupShares = ISyrup(SYRUP_POOL).balanceOf(address(vault));
        uint256 syrupValue = ISyrup(SYRUP_POOL).convertToAssets(syrupShares);

        // totalAssets should equal the USDT balance + Syrup value.
        assertEq(ta, IERC20(USDT).balanceOf(address(vault)) + syrupValue);
    }

    function test_fork_deposit_multipleUsers() public {
        // Fund bob.
        address bob = makeAddr("bob");
        vm.prank(USDT_WHALE);
        IERC20(USDT).transfer(bob, 50_000e6);
        vm.prank(bob);
        IERC20(USDT).approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(bob);
        vault.deposit(20_000e6, bob);

        assertTrue(vault.balanceOf(alice) > 0);
        assertTrue(vault.balanceOf(bob) > 0);
        assertTrue(vault.totalAssets() > 0);
    }

    function test_fork_requestRedeem() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(aliceShares, alice, alice);

        // Async: returns 0.
        assertEq(assets, 0);
        assertEq(vault.balanceOf(alice), 0);

        // Pending request exists.
        (uint256 syrupSh, uint256 villaSh, address receiver) = vault.getWithdrawalRequest(alice);
        assertTrue(syrupSh > 0);
        assertEq(villaSh, aliceShares);
        assertEq(receiver, alice);
    }

    function test_fork_previewDeposit_accurate() public {
        uint256 amount = 25_000e6;
        uint256 preview = vault.previewDeposit(amount);

        vm.prank(alice);
        uint256 actual = vault.deposit(amount, alice);

        assertEq(actual, preview, "Preview should match actual deposit");
    }

    function test_fork_exchangeRate_reflectsReal() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Check that the Syrup pool's convertToAssets reflects a rate >= 1:1
        // (Syrup accrues yield, so rate should be >= 1).
        uint256 syrupShares = ISyrup(SYRUP_POOL).balanceOf(address(vault));
        uint256 syrupAssets = ISyrup(SYRUP_POOL).convertToAssets(syrupShares);

        // The value should be >= the net deposit (possibly higher if Syrup has accrued yield).
        assertTrue(syrupAssets >= 9_900e6 - 1, "Syrup value should be >= net deposit");
    }
}
