// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockSyrup
/// @notice Simulates the Maple Syrup Pool for unit testing.
/// @dev Supports deposit, requestRedeem, redeem, convertToAssets, and balanceOf.
///      Exchange rate is controllable via `setExchangeRate()` to simulate yield accrual.
///      Redemption requests are tracked and must be manually "processed" by calling `processRequest`.
contract MockSyrup is ERC20 {
    IERC20 public immutable asset;

    /// @dev Exchange rate scaled to 1e18. 1e18 = 1:1 (one Syrup share = one USDT).
    uint256 public exchangeRate = 1e18;

    /// @dev Tracks pending redeem requests per owner.
    mapping(address => uint256) public pendingRedeems;

    /// @dev Whether a pending request has been "processed" (ready to claim).
    mapping(address => bool) public requestProcessed;

    constructor(address _asset) ERC20("Syrup Pool Share", "SYR") {
        asset = IERC20(_asset);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Sets the exchange rate (simulating yield accrual).
    /// @param _rate New rate scaled by 1e18 (e.g. 1.05e18 = 5% profit).
    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    /// @notice Deposit underlying assets and mint pool shares.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // shares = assets * 1e18 / exchangeRate
        shares = (assets * 1e18) / exchangeRate;
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    /// @notice Request redemption — locks shares in the mock queue.
    function requestRedeem(uint256 shares, address owner) external {
        // Transfer shares from owner to this contract to simulate locking.
        _transfer(owner, address(this), shares);
        pendingRedeems[owner] += shares;
    }

    /// @notice Redeem previously requested shares. Reverts if not processed.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(requestProcessed[owner], "MockSyrup: not processed");
        require(pendingRedeems[owner] >= shares, "MockSyrup: insufficient pending");

        pendingRedeems[owner] -= shares;
        if (pendingRedeems[owner] == 0) {
            requestProcessed[owner] = false;
        }

        assets = convertToAssets(shares);
        _burn(address(this), shares);
        asset.transfer(receiver, assets);
    }

    /// @notice Convert shares to assets using the current exchange rate.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    /// @dev Test helper: mark a pending request as processed (simulates Maple processing the queue).
    function processRequest(address owner) external {
        require(pendingRedeems[owner] > 0, "MockSyrup: no pending");
        requestProcessed[owner] = true;
    }

    /// @dev Test helper: mint USDT to the pool to back withdrawals after yield increase.
    function fundPool(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
    }
}
