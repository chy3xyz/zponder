---
order: 4
---

# WebSocket live indexing

When `[rpc].ws_url` or `[rpc].ws_urls` is configured, each indexer catches up to the chain tip over HTTP `eth_getLogs` and then switches to WebSocket `eth_subscribe("logs")`.

## Lifecycle

```
Historical sync (HTTP eth_getLogs)
        │
        ▼
  Caught up to tip?
   ┌────┴────┐
   │         │
  No        Yes
   │         │
   ▼         ▼
Next batch  ws_url configured?
            ┌────┴────┐
            │         │
           No        Yes
            │         │
            ▼         ▼
     HTTP polling    HTTP bridgeToTip (inclusive of tip block)
                     → WSS eth_subscribe("logs")
                     → recoverDroppedLive over HTTP
                     → read loop (fillLiveGap + processLog)
                     → on disconnect / new clone: close → bridgeToTip → resubscribe
```

| Phase | Transport | RPC methods |
|---|---|---|
| Historical catch-up | HTTP/HTTPS | `eth_blockNumber`, `eth_getLogs`, `eth_getBlockReceipts`, `eth_getBlockByNumber` |
| Tip without `ws_url` | HTTP/HTTPS | Periodic `eth_blockNumber` + `eth_getLogs` when head advances |
| Tip with `ws_url` | WS/WSS + HTTP gap fill | `eth_subscribe("logs")`, HTTP `eth_getLogs` for skipped blocks, `eth_getBlockByNumber` for reorg checks |

## Configuration

```toml
[rpc]
url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
ws_url = "wss://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
ws_urls = [
  "wss://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
  "wss://backup.example/ws",
]
request_timeout_ms = 10000
retry_count = 3
```

- `ws_url` and `ws_urls` are optional. When both are present, `zponder` rotates across `ws_urls` on reconnect.
- Every WebSocket URL must start with `ws://` or `wss://`. Invalid schemes fail `zponder check` and startup validation.
- `[rpc].url` is always required: historical catch-up, gap bridging, block hash checks, and `eth_call` use HTTP.

For a local Anvil node, HTTP and WebSocket share the same port:

```toml
[rpc]
url = "http://localhost:8545"
ws_url = "ws://localhost:8545"
```

## Runtime behavior

- **Bridge to tip**: before opening a subscription (and after every reconnect), `bridgeToTip` scans through `latest` inclusive (`cursor <= latest`) over HTTP so the tip block itself is not missed before the subscription becomes active.
- **Template multi-subscription chunking**: template indexers hold a dynamic set of clone addresses. `runLiveWs` splits the active address list into disjoint slices of at most `max_addresses_per_request` (default `200`) and sends one `eth_subscribe("logs")` per slice on the same WebSocket session. When a template has zero live addresses, it waits in the polling loop instead of subscribing with an empty address filter.
- **Handshake log recovery**: if the server pushes `eth_subscription` notifications while subsequent `eth_subscribe` acknowledgments are still in flight, `Session` records the highest pushed block (`dropped_live_hi`) and `recoverDroppedLive` backfills `[cursor, dropped_live_hi]` over HTTP before the live read loop advances the cursor.
- **Dynamic clone discovery**: when a factory discovers a new template clone address, `discoverAddress` interrupts the active WebSocket session so the template indexer backfills the new clone over HTTP and resubscribes with the updated address set.
- **Skipped-block gap fill**: if a live notification arrives for block `B` while the cursor is at `C < B`, `fillLiveGap` fetches `[C, B - 1]` over HTTP before processing the live log. If the gap fill fails, the live log is recorded in `raw_logs` and the session breaks back to `bridgeToTip`.
- **Monotonic cursor**: live logs never rewind `sync_state.last_synced_block` when multiple logs arrive for the same block or out of order; after block `B` is processed, the cursor is `max(cursor, B + 1)`.
- **Idle timeout**: when `request_timeout_ms > 0`, WebSocket reads use a 120-second idle timeout (`ws_rpc.idle_timeout_ms = 120_000`) rather than the shorter HTTP timeout, preventing unnecessary reconnects on quiet contracts while still cutting dead connections.
- **Reorg handling**: if a live notification arrives with `"removed": true` or the periodic 30-second block hash check detects a fork, the indexer rolls back from the fork block and breaks out to `bridgeToTip`.
