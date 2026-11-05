# Reorg / WSS 真实端到端验收

两套脚本各自启动独立的 anvil、zponder 和临时 SQLite；不会使用 8545。默认执行 `zig build`，随后把二进制复制到 `/tmp` 的独立工作目录，实际运行该副本。可用 `ZPOND_BIN=/path/to/zponder` 跳过构建并复制指定二进制，也可用 `SKIP_BUILD=1` 复用 `zig-out/bin/zponder`。

## A. 真实链上重组回滚

```bash
bash examples/local-demo/reorg-wss-demo/reorg/run.sh
```

默认端口：anvil `8621`、HTTP API `8622`，可用 `ANVIL_PORT` / `HTTP_PORT` 覆盖。

流程：部署 `Ping.sol`，保留分叉前的 `Ping(0)`；在快照后索引 `Ping(1..3)`；`evm_revert` 后用不同交易在同一高度写入 `Ping(101..103)`，再挖空块触发哈希检测。`block_batch_size=1` 用于保存逐块哈希，从而精确断言分叉点。

SQL/链上断言：

- 分叉高度的区块哈希确实变化，旧交易对应事件行全部删除。
- 分叉前事件保留；替换事件在原高度只出现一次，无重复唯一键。
- SQLite 触发器捕获到 `sync_state.status='reorg_rollback'` 且游标等于分叉点，最终游标再次推进。
- 本地分叉块哈希更新为新链哈希。
- `raw_logs` 没有死信；事件表与 canonical `eth_getLogs` 数量一致。

## B. WSS 断线重连

```bash
bash examples/local-demo/reorg-wss-demo/wss/run.sh
```

默认端口：anvil `8623`、TCP 代理 `8624`、HTTP API `8625`，可分别用 `ANVIL_PORT` / `PROXY_PORT` / `HTTP_PORT` 覆盖。HTTP RPC 直连 anvil，只有 `eth_subscribe(logs)` 经过代理。

流程：HTTP catch-up 切入 WSS；索引断线前事件；`SIGKILL` 代理并在断线窗口继续发交易；同端口重启代理；确认第二次订阅激活后再发交易。

SQL/链上断言：

- 日志出现断线检测、重连退避、连接失败和第二次订阅激活。
- 断线前、断线中、重连后的每笔交易都恰好索引一次。
- `(tx_hash, log_index, contract_address)` 无重复，`raw_logs` 无死信。
- 数据库三元组集合与链上六条 canonical `eth_getLogs` 完全相等，不多不少。

## 清理与已知问题

脚本通过 `trap` 清理自己启动的全部进程，结束时打印 `artifacts:` 路径。数据库、配置和日志保留供排查，确认路径后可删除：

```bash
rm -rf /path/printed/as/artifacts
```

**BUG（未修改 `src/`）**：HTTP 轮询在 `block_batch_size=1` 时，会在当前游标等于 `eth_blockNumber` 时先进入“已追平”分支，但该 tip 块实际尚未扫描；没有后续块时，该块事件一直缺失。reorg 脚本默认额外挖一个空块规避。去掉规避可复现为 `initial Ping rows: expected '4', got '3'`：

```bash
SYNC_TIP_WORKAROUND=0 ZPOND_BIN=/path/to/zponder \
  bash examples/local-demo/reorg-wss-demo/reorg/run.sh
```

此外，重组共同祖先只能利用已保存的批次末块哈希；批次较大时可能保守回滚到安全深度，而非精确分叉点。本验收用逐块哈希验证精确回滚路径。
