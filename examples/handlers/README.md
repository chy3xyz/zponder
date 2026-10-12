# zponder Handler 脚本与规则示例

本目录提供贴近真实业务的 zponder handler 示例，放入 `./handlers/`（或本目录）即自动扫描加载，无需重新编译。

## 快速落地三步

1. 在 `config.toml` 配置合约（name / address / abi_path / events）
2. 把本目录的示例复制到 `./handlers/`，改合约名与字段
3. `zponder start -c config.toml`

---

## 一、JavaScript 事件处理器（`ponder.on`）

**当前 API 签名**：

```javascript
ponder.on("合约名:事件名", (event) => {
  const { field1, field2 } = event.args;   // 事件的非 indexed 与 indexed 参数
  const blockNumber = event.block.number;  // 区块号
});
```

要点：
- `event.args` 里 **uint/int 值是 hex 字符串**（如 `"0xde0b6b3a7640000"`），用 `BigInt(...)` 解析
- `address` 是 `"0x..."` 字符串；`bool` 是 `"true"/"false"`
- `event.block.number` 是数字
- 支持 `"Contract:Event"` 全名与 `"Event"` 简写两种匹配

### 示例清单

| 文件 | 业务场景 |
|---|---|
| `dex_swap_monitor.js` | DEX Swap 价格计算与方向判断（USDC/ETH 交易对） |
| `erc20_whale_alert.js` | ERC20 大额转账监控、鲸鱼告警、铸币/销毁识别 |
| `nft_tracker.js` | ERC721 NFT 铸造/交易/销毁追踪 |

---

## 二、Webhook 告警（JSON 规则）

JS handler 侧重「事件处理 + 日志」；**推送到 Telegram/Slack 的 webhook 告警用 JSON 规则**（声明式，无需写代码）：

```json
[
  {
    "contract": "USDC",
    "event": "Transfer",
    "field": "value",
    "op": "gte",
    "val": "1000000000000",
    "action": {
      "type": "webhook",
      "url": "https://api.telegram.org/botYOUR_TOKEN/sendMessage"
    }
  }
]
```

- `op` 支持 `gt` / `gte` / `lt` / `lte` / `eq`
- `action.type` 支持 `log`（日志）与 `webhook`（HTTP 推送）
- 参考 `whale_alert.json`、`multi_contract_rules.json`

---

## 三、自定义 HTTP API（`ponder.http`，Hono 风格）

```javascript
// 中间件：鉴权
ponder.http.use((c, next) => {
  if (c.req.query("api_key") !== "secret123") {
    c.status(401);
    return c.json({ error: "invalid api_key" });
  }
  next();
});

// 路由 + 路径参数 + 响应
ponder.http.get("/api/wei/:amount", (c) => {
  const wei = c.req.param("amount");
  return c.json({ eth: Number(wei) / 1e18 });
});

ponder.http.post("/api/echo", (c) => {
  return c.json({ received: c.req.body() });
});
```

完整 API：`get/post/put/delete`、`c.req.param/query/body`、`c.json/c.text`、`c.status/c.header`、`use` 中间件。
参考 `custom_api.js`。

端点挂在 HTTP 服务（默认 `http://localhost:8080`）上，与内置 REST/GraphQL 共存。

---

## 四、业务投影写库（`ponder.db`）

把事件写成派生表（K 线、聚合、快照）。参数化绑定，不用拼字符串。

```javascript
// 建表放脚本顶层：加载时执行一次
ponder.db.exec(`
  CREATE TABLE IF NOT EXISTS proj_erc20_kline (
    block_number INTEGER NOT NULL PRIMARY KEY,
    ts           INTEGER NOT NULL,
    total        TEXT NOT NULL,
    tx_count     INTEGER NOT NULL DEFAULT 0
  );
`);

ponder.on("ERC20:Transfer", (event) => {
  const { from, to, value } = event.args;
  const amount = String(BigInt(value || "0x0"));

  // 逐笔明细
  ponder.db.exec(
    "INSERT OR REPLACE INTO proj_erc20_flow (block_number, ts, from_addr, to_addr, amount) VALUES (?, ?, ?, ?, ?);",
    event.block.number, event.block.timestamp, from, to, amount,
  );

  // 每块聚合（K 线柱）：同块多笔累加
  ponder.db.exec(
    `INSERT INTO proj_erc20_kline (block_number, ts, total, tx_count) VALUES (?, ?, ?, 1)
     ON CONFLICT(block_number) DO UPDATE SET
       total = CAST(CAST(total AS INTEGER) + CAST(excluded.total AS INTEGER) AS TEXT),
       tx_count = tx_count + 1;`,
    event.block.number, event.block.timestamp, amount,
  );
});
```

API：

| 调用 | 说明 |
|------|------|
| `ponder.db.exec(sql, ...params)` | 写语句（DDL/DML），返回 affected rows |
| `ponder.db.query(sql, ...params)` | 查询，返回行对象数组（列名为 key） |

- 参数用 `?` 占位（SQLite）/ `$1..$n`（PostgreSQL），值类型：`number`（整数值存 INTEGER，否则 REAL）、`string`、`boolean`、`null`、`ArrayBuffer`（BLOB）
- 结果类型：INTEGER/REAL → number，TEXT → string，BLOB → ArrayBuffer，NULL → null
- 后端：SQLite / PostgreSQL 可用；RocksDB 无 SQL，调用时抛错
- 投影表命名约定 `proj_` 前缀 + 必须含 `block_number` 列：**重组回滚时引擎按 `block_number >= fork_point` 级联删除**，不会留下脏数据
- 写入失败不中断索引：`log.err` + `/metrics` 的 `zponder_projection_errors_total` 计数，修好后删表重放即可
- 参考 `erc20_projection.js`

---

## 说明

- 索引数据查询用内置 **REST**（`/events/:contract/:event`）或 **GraphQL**（`/graphql`）；`ponder.http` 适合自定义轻量接口
- 实时事件流用 **SSE**（`/stream`）或 **GraphQL Subscription**（`newBlocks`）
- **同一事件键只保留最后注册的 handler**：多个脚本对 `Contract:Event`（或裸 `Event`）重复注册时后者覆盖前者，建议一个事件只有一个归属脚本
