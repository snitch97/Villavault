// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISyrup
/// @notice Minimal interface for the Maple Finance Syrup Pool (v2).
/// @dev Covers deposit, async redemption (request + claim), balance, and conversion queries.
interface ISyrup {
    /// @notice Deposits `assets` of the underlying token and mints pool shares to `receiver`.
    /// @param assets Amount of underlying tokens to deposit.
    /// @param receiver Address that will receive the minted pool shares.
    /// @return shares Amount of pool shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Requests an asynchronous redemption of `shares` on behalf of `owner`.
    /// @dev The shares enter the Maple WithdrawalManager queue and cannot be transferred until processed.
    /// @param shares Amount of pool shares to queue for redemption.
    /// @param owner Address that owns the shares being redeemed.
    function requestRedeem(uint256 shares, address owner) external;

    /// @notice Claims a previously requested redemption once the WithdrawalManager has processed it.
    /// @param shares Amount of pool shares to redeem (must match or be within the processed amount).
    /// @param receiver Address that will receive the underlying assets.
    /// @param owner Address that owns the shares being redeemed.
    /// @return assets Amount of underlying assets returned.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Converts a given amount of pool shares to their current underlying asset value.
    /// @param shares Amount of pool shares.
    /// @return assets Equivalent amount of underlying assets.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the pool share balance of `account`.
    /// @param account Address to query.
    /// @return balance Amount of pool shares held.
    function balanceOf(address account) external view returns (uint256 balance);
}
