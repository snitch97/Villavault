# VillaVault

ERC-4626 tokenized vault that wraps the [Maple Finance Syrup](https://syrup.fi/) USDT pool, adding management and performance fees with a high-water mark mechanism.

## Architecture

```
User ──deposit()──► VillaVault ──deposit()──► Maple Syrup Pool
User ◄──processRedeem()── VillaVault ◄──redeem()── Maple Syrup Pool
```

- **Deposits** are atomic: USDT is swept into Syrup immediately after deducting the management fee.
- **Withdrawals** are asynchronous (two-step): `redeem()` submits a request to Maple's WithdrawalManager queue; `processRedeem()` claims the USDT once Maple has processed it.
- **Villa shares** (ERC-20) represent a proportional claim on the vault's Syrup position.
- Inherits OpenZeppelin v5 `ERC4626` for virtual-shares inflation-attack protection.

## Fee Structure

| Fee | Rate | Mechanism |
|-----|------|-----------|
| Management fee | 1% (100 BP) | Deducted from each deposit in USDT, sent to `feeRecipient` |
| Performance fee | 5% (500 BP) | Minted as Villa shares on profit above a global high-water mark (HWM) |

- Both fee parameters and the fee recipient are **immutable** (set at deployment).
- Performance fees are accrued automatically before every deposit and redemption.
- The HWM ensures fees are only charged on *new* profits, preventing double-charging.

## Build

```bash
forge build
```

## Test

Unit tests (mocked Syrup):

```bash
forge test --match-contract VillaVaultTest -v
```

Fork tests (real Syrup on mainnet):

```bash
forge test --match-contract VillaVaultForkTest --fork-url $MAINNET_RPC_URL -vvv
```

Coverage:

```bash
forge coverage --no-match-contract Fork
```

## Deploy

```bash
# Sepolia
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv

# Mainnet
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv
```

The deploy script auto-detects the network via `block.chainid` and uses the correct USDT/Syrup addresses.

### Environment Variables

Copy `.env` and fill in:

| Variable | Description |
|----------|-------------|
| `PRIVATE_KEY` | Deployer private key |
| `MAINNET_RPC_URL` | Ethereum mainnet RPC |
| `SEPOLIA_RPC_URL` | Sepolia testnet RPC |
| `ETHERSCAN_API_KEY` | For contract verification |

## Contract Addresses

| Network | Contract | Address |
|---------|----------|---------|
| Sepolia | VillaVault | [`0xBD8dDf12950a805aB0437b922B82D641E8BeE03D`](https://sepolia.etherscan.io/address/0xBD8dDf12950a805aB0437b922B82D641E8BeE03D) |
| Sepolia | MockSyrup | [`0xEcF55D28372a631dcD507ee348a8b106d86630D0`](https://sepolia.etherscan.io/address/0xEcF55D28372a631dcD507ee348a8b106d86630D0) |
| Mainnet | VillaVault | *Not yet deployed* |

## Security

Static analysis with Slither:

```bash
slither src/VillaVault.sol
```

Key design choices:
- **Immutable fees**: No admin function to change fee rates or recipient post-deployment.
- **No pause/emergency withdrawal**: Reduces admin risk surface.
- **CEI pattern**: State is cleared before external calls in `processRedeem`.
- **SafeERC20**: All USDT transfers use `safeTransfer` / `safeTransferFrom`.
- **Pool cap**: Owner can set `maxPoolAmount` to limit TVL.

## License

MIT
