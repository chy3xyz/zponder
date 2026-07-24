# WSS 订阅索引

zponder 支持可选的 WebSocket（`ws://` / `wss://`）直播索引，用于在追上链 tip 后通过 `eth_subscribe("logs")` 接收事件，降低 HTTP 轮询带来的 RPC 调用成本。

---

## 行为概览

```
历史回填 (HTTP eth_getLogs)
        │
        ▼
   追上 tip？
   ┌────┴────┐
   │         │
  否        是
   │         │
   ▼         ▼
继续 batch   已配置 ws_url？
            ┌────┴────┐
            │         │
           否        是
            │         │
            ▼         ▼
     eth_blockNumber   HTTP gap bridge
     + sleep 轮询      → WSS eth_subscribe(logs)
                       → processLog / 推进 sync_state
                       → 断线：backoff → bridge → 重订阅
```

| 阶段 | 传输 | RPC 方法 |
|------|------|----------|
| 历史追赶 | HTTPS/HTTP | `eth_blockNumber`、`eth_getLogs`、`eth_getBlockByNumber` |
| Tip（无 `ws_url`） | HTTPS/HTTP | 周期性 `eth_blockNumber` + 有新块时再 `eth_getLogs` |
| Tip（有 `ws_url`） | WSS/WS | `eth_subscribe("logs")` 推送；重组检测仍可能用 HTTP 查 hash |

---

## 配置

### 基本用法

```toml
[rpc]
url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
ws_url = "wss://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
timeout = 10000
retry_count = 3
```

### 故障转移

与 HTTP `urls` 类似，可配置多条 WSS：

```toml
[rpc]
url = "https://primary.example/rpc"
ws_url = "wss://primary.example/ws"
ws_urls = [
  "wss://primary.example/ws",
  "wss://backup.example/ws",
]
```

连接时优先轮询 `ws_urls`；若为空则使用 `ws_url`。

### 校验规则

- `ws_url` / `ws_urls` 均为**可选**；未配置时 tip 阶段保持原轮询行为。
- 若配置，scheme 必须为 `ws://` 或 `wss://`（`https://` 会在 `zponder check` / 启动校验时失败）。
- HTTP `url` 仍为必填（历史回填、重组 hash、`eth_call` 等继续走 HTTP）。

### 本地 Anvil

Anvil 在同一端口提供 HTTP 与 WebSocket：

```toml
[rpc]
url = "http://localhost:8545"
ws_url = "ws://localhost:8545"
```

---

## 实现要点

| 项 | 说明 |
|----|------|
| 模块 | [`src/ws_rpc.zig`](../src/ws_rpc.zig)（握手 + 帧 + subscribe）；[`src/indexer.zig`](../src/indexer.zig) `runLiveWs` |
| 连接模型 | **每个合约索引器一条** WSS（与一合约一线程一致）；工厂子合约同样继承 `[rpc]` 的 `ws_url` |
| 过滤 | `address` + topic0 OR（`[["sig1","sig2",...]]`），与 HTTP `eth_getLogs` 一致 |
| Gap bridge | 切入订阅前、重连后用 HTTP `eth_getLogs` 从 `current` 追到 tip，避免漏块 |
| 保活 | 客户端响应服务端 `ping` → `pong` |
| 重连 | 指数退避（约 500ms × 2^n，上限约 16s） |
| 重组 | 订阅日志若带 `removed: true` 则按块回滚；另约每 30s 做一次 hash 重组检测 |
| 停止 | `Indexer.stop()` 会 shutdown 当前 WSS，解除阻塞读 |

本期**未做**：多合约共享单条 WSS、`newHeads` 路径、第三方 WebSocket 依赖库。

---

## 成本与运维建议

1. **何时开启**：已追上 tip、且节点提供可靠 `eth_subscribe`（Alchemy / Infura / QuickNode / 自建 geth/erigon 等）时收益最大。
2. **历史回填仍耗 CU**：大区间追块仍依赖 `eth_getLogs`；WSS 主要省 tip 空转时的 `eth_blockNumber` 轮询。
3. **公共免费节点**：不少公共 RPC **不支持** WSS 或限制订阅；失败时会重连并短暂回退 bridge，请换专业节点。
4. **BSC / 限流节点**：可同时调小 `block_batch_size`、适当增大 `poll_interval_ms`（仅影响无 WSS 或 bridge 阶段）。
5. **观察日志**：
   - `已追上 tip … 切换到 WSS 订阅模式`
   - `eth_subscribe(logs) 成功`
   - `WSS 将在 …ms 后重连`

---

## 手测清单

- [ ] 仅配置 `url`：行为与升级前一致（tip 轮询）。
- [ ] 配置合法 `ws_url`：追上 tip 后日志出现订阅成功，新事件仍写入 DB / 触发 handler。
- [ ] 配置非法 scheme（如 `https://...`）：`zponder check` 报错。
- [ ] 断开 WSS（杀代理 / 断网）：出现重连日志，恢复后无持续漏块（bridge 补齐）。
- [ ] Anvil：`ws_url = "ws://localhost:8545"`，`cast send` 触发 Transfer 后 API 可查到。

---

## 相关文件

| 文件 | 角色 |
|------|------|
| `src/ws_rpc.zig` | WebSocket 客户端 + `eth_subscribe` |
| `src/eth_rpc.zig` | HTTP JSON-RPC；`Log.removed` / 过滤格式化 |
| `src/indexer.zig` | `runLiveWs`、bridge、removed 回滚 |
| `src/config.zig` | `ws_url` / `ws_urls` 解析与校验 |
| `config.toml` | 注释示例 |
| `docs/ARCHITECTURE.md` | 架构层说明 |
