# Local Demo — End-to-End zponder Example

This example runs a complete local demo of zponder indexing an ERC20 token contract
on a local Anvil Ethereum node.

## Architecture

```
┌──────────┐     ┌──────────────┐     ┌──────────────┐
│  Anvil   │────▶│   zponder    │────▶│    SQLite    │
│ (8545)   │     │  indexer     │     │  demo.db     │
└──────────┘     └──────┬───────┘     └──────────────┘
                        │
                 ┌──────┴───────┐
                 │  REST API    │  :9090/health, /events, /sync_state
                 │  GraphQL API │  :9091/graphql, /graphql/playground
                 └──────────────┘
```

## Prerequisites

- [Zig](https://ziglang.org/) 0.16.0+
- [Foundry](https://book.getfoundry.sh/) (provides `anvil` + `cast`)
- `brew install zig sqlite3 rocksdb libpq` (macOS)

## Quick Start

```bash
# From the zponder project root:
bash examples/local-demo/run.sh
```

The script:
1. Starts Anvil (local Ethereum node on port 8545)
2. Compiles and deploys a DemoToken ERC20 contract
3. Sends 3 transfer transactions to generate events
4. Builds zponder (if not already built)
5. Starts zponder with the demo configuration
6. Indexes all Transfer events (blocks 0–4)
7. Prints REST API + GraphQL API query results

## Files

| File | Purpose |
|------|---------|
| `run.sh` | Automated demo script |
| `DemoToken.sol` | Minimal ERC20 contract used for testing |
| `config.toml` | zponder configuration for the demo |

## Expected Output

After running, you should see:

```
╔════════════════════════════════════════════════════════════╗
║           zponder v0.3.0 — Local Demo                    ║
╠════════════════════════════════════════════════════════════╣
║  REST API : http://localhost:9090                        ║
║  GraphQL  : http://localhost:9091/graphql                 ║
║  Chain    : Anvil (localhost:8545)                        ║
║  Contract : DemoToken ERC20                              ║
║  Events   : Transfer — 4 events indexed (blocks 1–4)     ║
╚════════════════════════════════════════════════════════════╝

=== REST: /events/demo/Transfer?limit=3 ===
[
  {
    "evt_from": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "evt_to": "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    "evt_value": "0x0000000000000000000000000000000000000000000000056bc75e2d63100000",
    "block_number": 4,
    "tx_hash": "0xbc0d9e..."
  },
  ...
]

=== GraphQL: latestEvents ===
{
  "data": {
    "latestEvents": [
      {
        "blockNumber": 4,
        "transactionHash": "0xbc0d9e...",
        "eventName": "Transfer",
        "fields": [...]
      }
    ]
  }
}

=== GraphQL: contractCall ===
{
  "data": {
    "contractCall": "1000000000000000000000000"
  }
}
```

## Cleanup

```bash
pkill -f anvil
pkill -f zponder
rm -f demo_indexer.db*
```
