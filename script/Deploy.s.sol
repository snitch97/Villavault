// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VillaVault} from "../src/VillaVault.sol";

/// @title Deploy
/// @notice Deployment script for VillaVault. Supports both Sepolia and Mainnet.
/// @dev Usage:
///   Sepolia:  forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
///   Mainnet:  forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv
contract Deploy is Script {
    // ── Mainnet addresses ────────────────────────────────────────────────────
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant MAINNET_SYRUP = 0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;

    // ── Sepolia addresses ────────────────────────────────────────────────────
    address constant SEPOLIA_USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;
    address constant SEPOLIA_SYRUP = 0x3EB612858EE843eBb14Df37b9Ec2c7c82B23eE2B;

    // ── Fee configuration ────────────────────────────────────────────────────
    address constant FEE_RECIPIENT = 0x6AfDD1DaD70708230aC27620775df9897938a76D;
    uint256 constant MANAGEMENT_FEE_BP = 100;  // 1%
    uint256 constant PERFORMANCE_FEE_BP = 500; // 5%
    uint256 constant MAX_POOL_AMOUNT = 10_000_000e6; // 10M USDT initial cap

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Detect network by chain ID.
        uint256 chainId = block.chainid;

        address usdt;
        address syrupPool;

        if (chainId == 1) {
            // Mainnet
            usdt = MAINNET_USDT;
            syrupPool = MAINNET_SYRUP;
            console.log("Deploying to Mainnet...");
        } else if (chainId == 11155111) {
            // Sepolia
            usdt = SEPOLIA_USDT;
            syrupPool = SEPOLIA_SYRUP;
            console.log("Deploying to Sepolia...");
        } else {
            revert("Unsupported chain ID");
        }

        console.log("Deployer:", deployer);
        console.log("USDT:", usdt);
        console.log("Syrup Pool:", syrupPool);

        vm.startBroadcast(deployerPrivateKey);

        VillaVault vault = new VillaVault(
            usdt,
            syrupPool,
            FEE_RECIPIENT,
            MANAGEMENT_FEE_BP,
            PERFORMANCE_FEE_BP,
            MAX_POOL_AMOUNT,
            deployer // deployer is owner
        );

        console.log("VillaVault deployed at:", address(vault));

        vm.stopBroadcast();
    }
}
