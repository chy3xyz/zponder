# zponder Examples

## Local Demo (`local-demo/`)

Full end-to-end demo that runs a local Anvil Ethereum node, deploys an ERC20 token,
indexes Transfer events with zponder, and queries both REST and GraphQL APIs.

```bash
# From the project root:
bash examples/local-demo/run.sh
```

**Prerequisites:** Zig 0.16.0+, Foundry (anvil + cast), solc, sqlite3

**What it does:**
1. Starts Anvil (local Ethereum node on port 8545)
2. Compiles and deploys a DemoToken ERC20 contract
3. Sends 3 transfer transactions to generate events
4. Builds zponder (if not already built)
5. Starts zponder with demo configuration
6. Indexes all Transfer events (blocks 0–4)
7. Queries REST API (`/health`, `/events`, `/sync_state`, `/version`)
8. Queries GraphQL API (`contracts`, `syncStates`, `latestEvents`, `contractCall`)

**Files:**
- `run.sh` — automated demo script
- `DemoToken.sol` — minimal ERC20 contract
- `DemoToken.abi` — compiled ABI
- `config.toml` — zponder configuration

---

## Kline Chart (`kline.html`)

Interactive OHLC candlestick chart from on-chain Swap events.

Open `examples/kline.html` in a browser.

**Features:**
- Fetches Swap events from zponder REST API
- Aggregates into OHLC candles (1m / 5m / 15m / 1h / 4h)
- Built-in presets for PancakeSwap and Uniswap pairs
- Mock mode fallback when API is unavailable
- Rendered with TradingView Lightweight Charts v5

### Requirements

**Option 1: Connect to running zponder**

```bash
zig build run -- -c config.toml  # with Swap contract configured
# Then open kline.html in browser → select preset → load
```

**Option 2: Pure frontend demo (Mock mode)**

Just open `kline.html` — no zponder needed. Chart renders with mock data.

### PancakeSwap V2 Pair ABI

```json
[{
  "type": "event",
  "name": "Swap",
  "inputs": [
    {"name": "sender", "type": "address", "indexed": true},
    {"name": "amount0In", "type": "uint256", "indexed": false},
    {"name": "amount1In", "type": "uint256", "indexed": false},
    {"name": "amount0Out", "type": "uint256", "indexed": false},
    {"name": "amount1Out", "type": "uint256", "indexed": false},
    {"name": "to", "type": "address", "indexed": true}
  ]
}]
```

### How It Works

```
price = (amount0In + amount0Out) / (amount1In + amount1Out)  // token1 per token0

Per candle interval:
  open  = first price in interval
  high  = max(price)
  low   = min(price)
  close = last price in interval
  volume = Σ amount1
```

| Layer | Technology |
|-------|------------|
| Charts | TradingView Lightweight Charts v5 (CDN) |
| CSS | Tailwind CSS CDN |
| Framework | Vanilla JS (no build step) |
| Data | zponder HTTP API + mock fallback |
