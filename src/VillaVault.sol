// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISyrup} from "./interfaces/ISyrup.sol";

/// @title VillaVault
/// @author Villa Finance
/// @notice ERC-4626 tokenized vault wrapping Maple Syrup USDT pool with management and performance fees.
/// @dev Implements atomic deposits into Syrup, two-stage async withdrawals via Maple's WithdrawalManager v2 queue,
///      a 1% management fee on deposits, and a 5% performance fee on profits above a global high-water mark (HWM).
///      All fee parameters and the fee recipient are immutable — set once at deployment. Only the owner can
///      adjust `maxPoolAmount`. There are no pause, fee-change, or admin-withdrawal functions.
///      Inherits OpenZeppelin v5 ERC4626 for virtual shares/assets inflation-attack protection.
contract VillaVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Basis-point denominator (100% = 10 000 BP).
    uint256 public constant BP = 10_000;

    // ──────────────────────────────────────────────────────────────────────────
    // Immutables
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice The Maple Syrup pool contract.
    ISyrup public immutable syrup;

    /// @notice The underlying USDT token (cached for gas).
    IERC20 public immutable usdt;

    /// @notice Address that receives all management and performance fees.
    address public immutable feeRecipient;

    /// @notice Management fee in basis points (applied to incoming deposits).
    uint256 public immutable managementFeeBP;

    /// @notice Performance fee in basis points (applied to profit above HWM).
    uint256 public immutable performanceFeeBP;

    // ──────────────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Maximum total assets the vault will accept (set by owner).
    uint256 public maxPoolAmount;

    /// @notice High-water mark: the historical maximum of `totalAssets() / totalSupply()` scaled by 1e18.
    /// @dev Used for performance-fee calculation. Updated after each performance-fee accrual.
    uint256 public highWaterMark;

    /// @notice Total Syrup shares currently locked in pending withdrawal requests.
    uint256 public totalLockedSyrupShares;

    /// @dev Tracks each user's pending withdrawal request.
    struct WithdrawalRequest {
        uint256 syrupShares;   // Syrup shares locked for this request
        uint256 villaShares;   // Villa shares burned when the request was made
        address receiver;      // Who receives the underlying assets on claim
    }

    /// @notice Pending withdrawal requests per user.
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a withdrawal request is submitted to Maple.
    /// @param owner The Villa-share owner who initiated the request.
    /// @param receiver The address that will receive assets on claim.
    /// @param villaShares Villa shares burned.
    /// @param syrupShares Syrup shares locked in the request.
    event WithdrawalRequested(
        address indexed owner,
        address indexed receiver,
        uint256 villaShares,
        uint256 syrupShares
    );

    /// @notice Emitted when a pending redemption is processed (claimed) from Maple.
    /// @param owner The original requester.
    /// @param receiver The address that received the assets.
    /// @param assets Amount of USDT transferred.
    /// @param syrupShares Syrup shares that were redeemed.
    event RedemptionProcessed(
        address indexed owner,
        address indexed receiver,
        uint256 assets,
        uint256 syrupShares
    );

    /// @notice Emitted when performance fees are accrued.
    /// @param sharesMinted Villa shares minted to the fee recipient.
    /// @param newHWM Updated high-water mark.
    event PerformanceFeeAccrued(uint256 sharesMinted, uint256 newHWM);

    /// @notice Emitted when the owner updates the maximum pool amount.
    /// @param newMaxPoolAmount The new cap.
    event MaxPoolAmountUpdated(uint256 newMaxPoolAmount);

    // ──────────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when deposit would exceed the pool cap.
    error ExceedsMaxPoolAmount();

    /// @notice Thrown when a zero-amount operation is attempted.
    error ZeroAmount();

    /// @notice Thrown when the fee recipient address is the zero address.
    error ZeroFeeRecipient();

    /// @notice Thrown when the Syrup pool address is the zero address.
    error ZeroSyrupAddress();

    /// @notice Thrown when the user has no pending withdrawal request to process.
    error NoPendingRequest();

    /// @notice Thrown when the user already has a pending withdrawal request.
    error RequestAlreadyPending();

    /// @notice Thrown when an async withdrawal function receives a non-zero asset amount.
    error AsyncWithdrawalsOnly();

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Deploys the VillaVault.
    /// @param _usdt Address of the underlying USDT token.
    /// @param _syrup Address of the Maple Syrup pool.
    /// @param _feeRecipient Address that receives fees.
    /// @param _managementFeeBP Management fee in basis points (e.g. 100 = 1%).
    /// @param _performanceFeeBP Performance fee in basis points (e.g. 500 = 5%).
    /// @param _maxPoolAmount Initial deposit cap.
    /// @param _owner Initial contract owner.
    constructor(
        address _usdt,
        address _syrup,
        address _feeRecipient,
        uint256 _managementFeeBP,
        uint256 _performanceFeeBP,
        uint256 _maxPoolAmount,
        address _owner
    )
        ERC20("Villa Token", "Villa")
        ERC4626(IERC20(_usdt))
        Ownable(_owner)
    {
        if (_syrup == address(0)) revert ZeroSyrupAddress();
        if (_feeRecipient == address(0)) revert ZeroFeeRecipient();

        syrup = ISyrup(_syrup);
        usdt = IERC20(_usdt);
        feeRecipient = _feeRecipient;
        managementFeeBP = _managementFeeBP;
        performanceFeeBP = _performanceFeeBP;
        maxPoolAmount = _maxPoolAmount;

        // Initial HWM: 1:1 ratio, scaled to 1e18 precision.
        highWaterMark = 1e18;

        // Pre-approve Syrup pool to spend USDT held by this vault (max approval for gas savings).
        IERC20(_usdt).forceApprove(_syrup, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Owner functions
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Sets the maximum total assets the vault will accept.
    /// @dev Only callable by the owner. Emits {MaxPoolAmountUpdated}.
    /// @param _maxPoolAmount The new deposit cap (in USDT, 6-decimal).
    function setMaxPoolAmount(uint256 _maxPoolAmount) external onlyOwner {
        maxPoolAmount = _maxPoolAmount;
        emit MaxPoolAmountUpdated(_maxPoolAmount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 overrides — Asset accounting
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Returns the total underlying assets managed by the vault.
    /// @dev Sum of:
    ///      1. USDT held directly by the vault (transient or queued).
    ///      2. Syrup shares owned by the vault (free + locked), converted to USDT.
    /// @return Total assets denominated in USDT.
    function totalAssets() public view override returns (uint256) {
        uint256 usdtBalance = usdt.balanceOf(address(this));
        uint256 totalSyrupShares = syrup.balanceOf(address(this)) + totalLockedSyrupShares;
        uint256 syrupValue = totalSyrupShares > 0 ? syrup.convertToAssets(totalSyrupShares) : 0;
        return usdtBalance + syrupValue;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 overrides — Deposit limits
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Maximum assets a `receiver` can deposit, respecting the pool cap.
    /// @return Maximum deposit amount in USDT.
    function maxDeposit(address) public view override returns (uint256) {
        uint256 currentAssets = totalAssets();
        if (currentAssets >= maxPoolAmount) return 0;
        return maxPoolAmount - currentAssets;
    }

    /// @notice Maximum shares a `receiver` can mint, respecting the pool cap.
    /// @return Maximum share amount.
    function maxMint(address) public view override returns (uint256) {
        uint256 maxDep = maxDeposit(address(0));
        if (maxDep == 0) return 0;
        return _convertToShares(maxDep, Math.Rounding.Floor);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 overrides — Withdrawal limits (async)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Maximum assets an `owner` can withdraw synchronously.
    /// @dev Returns 0 because withdrawals are asynchronous via Maple's queue.
    ///      Users must call `redeem` to request, then `processRedeem` to claim.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Maximum shares an `owner` can redeem synchronously.
    /// @dev Returns 0 because redemptions are asynchronous.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 overrides — Preview functions
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Previews shares minted for a given deposit amount (after management fee).
    /// @param assets The gross USDT amount the user wants to deposit.
    /// @return shares Villa shares the user would receive.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = assets.mulDiv(managementFeeBP, BP, Math.Rounding.Ceil);
        uint256 netAssets = assets - fee;
        return _convertToShares(netAssets, Math.Rounding.Floor);
    }

    /// @notice Previews the gross USDT required to mint `shares` Villa tokens (including management fee).
    /// @param shares The number of Villa shares the user wants to receive.
    /// @return assets The gross USDT the user must provide.
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        // netAssets = grossAssets - fee = grossAssets * (BP - managementFeeBP) / BP
        // => grossAssets = netAssets * BP / (BP - managementFeeBP)
        return netAssets.mulDiv(BP, BP - managementFeeBP, Math.Rounding.Ceil);
    }

    /// @notice Preview for withdraw — always returns 0 (async only).
    function previewWithdraw(uint256) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Preview for redeem — returns the assets that would be received upon eventual claim.
    /// @dev This is an estimate; actual amount depends on Syrup's rate at claim time.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 overrides — Deposit
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Deposits USDT into the vault: deducts management fee, sweeps remainder into Syrup, mints Villa shares.
    /// @dev Overrides ERC4626.deposit to inject fee logic and Syrup sweep.
    /// @param assets Gross USDT amount to deposit (user must have approved this vault).
    /// @param receiver Address to receive the minted Villa shares.
    /// @return shares Amount of Villa shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        uint256 maxDep = maxDeposit(receiver);
        if (assets > maxDep) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxDep);
        }

        // Accrue performance fees before deposit to keep share price accurate.
        _accruePerformanceFee();

        // Calculate management fee and net deposit.
        uint256 fee = assets.mulDiv(managementFeeBP, BP, Math.Rounding.Ceil);
        uint256 netAssets = assets - fee;

        // Calculate shares from net assets.
        shares = _convertToShares(netAssets, Math.Rounding.Floor);
        if (shares == 0) revert ZeroAmount();

        // Transfer gross USDT from caller.
        usdt.safeTransferFrom(_msgSender(), address(this), assets);

        // Send management fee to recipient.
        if (fee > 0) {
            usdt.safeTransfer(feeRecipient, fee);
        }

        // Sweep net USDT into Syrup (return value intentionally unused — we track via balanceOf).
        // slither-disable-next-line unused-return
        syrup.deposit(netAssets, address(this));

        // Mint Villa shares to receiver.
        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, assets, shares);
    }

    /// @notice Mints exactly `shares` Villa tokens by depositing the required USDT (including management fee).
    /// @param shares Exact Villa shares to mint.
    /// @param receiver Address to receive the shares.
    /// @return assets Gross USDT pulled from the caller.
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();

        uint256 maxSh = maxMint(receiver);
        if (shares > maxSh) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxSh);
        }

        // Accrue performance fees before minting.
        _accruePerformanceFee();

        // Calculate net assets for the desired shares.
        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);

        // Gross assets including management fee.
        assets = netAssets.mulDiv(BP, BP - managementFeeBP, Math.Rounding.Ceil);
        uint256 fee = assets - netAssets;

        // Transfer gross USDT from caller.
        usdt.safeTransferFrom(_msgSender(), address(this), assets);

        // Send management fee.
        if (fee > 0) {
            usdt.safeTransfer(feeRecipient, fee);
        }

        // Sweep net USDT into Syrup (return value intentionally unused — we track via balanceOf).
        // slither-disable-next-line unused-return
        syrup.deposit(netAssets, address(this));

        // Mint Villa shares.
        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, assets, shares);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 overrides — Withdrawal (async request)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Initiates an asynchronous withdrawal request. Not supported — use `redeem` instead.
    /// @dev Always reverts because withdraw-by-assets is impractical with async queues.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert AsyncWithdrawalsOnly();
    }

    /// @notice Initiates an asynchronous redemption: burns Villa shares and locks equivalent Syrup shares
    ///         in Maple's withdrawal queue. Returns 0 assets (claim via `processRedeem`).
    /// @dev The caller must be the `owner` or have sufficient ERC-20 allowance.
    ///      Each owner can have at most one pending request at a time.
    /// @param shares Villa shares to redeem.
    /// @param receiver Address that will receive USDT when the request is processed.
    /// @param owner Address whose Villa shares are burned.
    /// @return assets Always 0 — actual assets are delivered via `processRedeem`.
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (withdrawalRequests[owner].syrupShares != 0) revert RequestAlreadyPending();

        // Spend allowance if caller is not the owner.
        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }

        // Accrue performance fees to keep share price accurate before redemption.
        _accruePerformanceFee();

        // Convert Villa shares → equivalent Syrup shares.
        // Villa shares represent a proportional claim on the vault's Syrup position.
        uint256 villaAssets = _convertToAssets(shares, Math.Rounding.Floor);
        // Now convert those USDT-denominated assets to Syrup shares.
        // We compute how many Syrup shares correspond to this portion of the vault.
        uint256 totalSyrup = syrup.balanceOf(address(this));
        uint256 totalVal = totalAssets();

        uint256 syrupSharesToLock = 0;
        if (totalVal > 0 && totalSyrup > 0) {
            // Proportional: syrupShares = totalFreeSyrup * villaAssets / totalVal
            syrupSharesToLock = totalSyrup.mulDiv(villaAssets, totalVal, Math.Rounding.Floor);
            // Cap to available free Syrup shares.
            if (syrupSharesToLock > totalSyrup) {
                syrupSharesToLock = totalSyrup;
            }
        }

        if (syrupSharesToLock == 0) revert ZeroAmount();

        // Burn Villa shares from owner.
        _burn(owner, shares);

        // Lock Syrup shares and submit request to Maple.
        totalLockedSyrupShares += syrupSharesToLock;
        withdrawalRequests[owner] = WithdrawalRequest({
            syrupShares: syrupSharesToLock,
            villaShares: shares,
            receiver: receiver
        });

        syrup.requestRedeem(syrupSharesToLock, address(this));

        emit WithdrawalRequested(owner, receiver, shares, syrupSharesToLock);

        // Per spec: returns 0 assets; actual delivery happens in processRedeem.
        return 0;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Async claim
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Processes (claims) a pending redemption from Maple once it has been fulfilled.
    /// @dev Calls `syrup.redeem()` which will revert if the request has not yet been processed by Maple.
    ///      Transfers the redeemed USDT to the original `receiver`. Anyone can call this on behalf of `owner`.
    /// @param owner The user whose pending request should be processed.
    /// @return assets Amount of USDT transferred to the receiver.
    function processRedeem(address owner) external returns (uint256 assets) {
        WithdrawalRequest memory req = withdrawalRequests[owner];
        if (req.syrupShares == 0) revert NoPendingRequest();

        // Clear the request before external calls (CEI pattern).
        delete withdrawalRequests[owner];
        totalLockedSyrupShares -= req.syrupShares;

        // Claim from Maple — sends USDT to this contract.
        assets = syrup.redeem(req.syrupShares, address(this), address(this));

        // Forward USDT to the receiver.
        if (assets > 0) {
            usdt.safeTransfer(req.receiver, assets);
        }

        emit RedemptionProcessed(owner, req.receiver, assets, req.syrupShares);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Performance fee
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Accrues the performance fee by comparing the current assets-per-share to the HWM.
    /// @dev If the current price exceeds the HWM, mints fee shares to dilute existing holders.
    ///      The fee is `performanceFeeBP` of the profit above the HWM. The HWM is updated afterward.
    ///      This is called automatically before deposits and redemptions.
    function accruePerformanceFee() external {
        _accruePerformanceFee();
    }

    /// @dev Internal performance-fee accrual logic.
    function _accruePerformanceFee() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return;

        uint256 assets_ = totalAssets();
        // Current assets per share, scaled to 1e18.
        uint256 currentPricePerShare = assets_.mulDiv(1e18, supply, Math.Rounding.Floor);

        if (currentPricePerShare <= highWaterMark) return;

        // Profit per share above HWM.
        uint256 profitPerShare = currentPricePerShare - highWaterMark;

        // Total profit across all shares.
        uint256 totalProfit = profitPerShare.mulDiv(supply, 1e18, Math.Rounding.Floor);

        // Fee in asset terms.
        uint256 feeAssets = totalProfit.mulDiv(performanceFeeBP, BP, Math.Rounding.Floor);

        if (feeAssets == 0) return;

        // Mint shares to fee recipient such that: feeShares / (supply + feeShares) = feeAssets / assets_
        // => feeShares = supply * feeAssets / (assets_ - feeAssets)
        uint256 denominator = assets_ - feeAssets;
        if (denominator == 0) return;

        uint256 feeShares = supply.mulDiv(feeAssets, denominator, Math.Rounding.Floor);

        if (feeShares == 0) return;

        _mint(feeRecipient, feeShares);

        // Update HWM to current price (post-dilution).
        // After minting feeShares the new price = assets_ / (supply + feeShares)
        highWaterMark = assets_.mulDiv(1e18, supply + feeShares, Math.Rounding.Floor);

        emit PerformanceFeeAccrued(feeShares, highWaterMark);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // View helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Returns the pending withdrawal request for a given `owner`.
    /// @param owner The address to query.
    /// @return syrupShares Locked Syrup shares.
    /// @return villaShares Villa shares that were burned.
    /// @return receiver The address that will receive the assets.
    function getWithdrawalRequest(address owner)
        external
        view
        returns (uint256 syrupShares, uint256 villaShares, address receiver)
    {
        WithdrawalRequest memory req = withdrawalRequests[owner];
        return (req.syrupShares, req.villaShares, req.receiver);
    }

    /// @notice Returns the number of free (not locked) Syrup shares held by the vault.
    /// @return Free Syrup share balance.
    function freeSyrupShares() external view returns (uint256) {
        return syrup.balanceOf(address(this));
    }
}
