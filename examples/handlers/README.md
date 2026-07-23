# zponder 动态 Handler 脚本与规则引擎示例

本目录提供了 **zponder 动态 Handler 脚本引擎** 的常见应用示例。

动态 Handler 脚本允许开发者通过 **JSON/JS 规则声明**，在无需重新编译 Zig 代码的前提下，实时过滤、监听链上合约事件，并触发日志告警或异步 HTTP Webhook 推送。

## JavaScript Handler 脚本示例 (Ponder 风格 API)

### 1. DEX 交易价格计算与巨鲸 Webhook 告警 (`swap_handler.js`)
```javascript
ponder.on("PancakePair:Swap", async ({ event, context }) => {
  const { sender, amount0In, amount1Out } = event.args;
  const in0 = BigInt(amount0In || "0");
  const out1 = BigInt(amount1Out || "0");

  if (in0 > 0n && out1 > 0n) {
    const price = Number(out1) / Number(in0);
    console.log(`[DEX Swap] Price: ${price.toFixed(6)}`);

    if (in0 >= 100000000000000000000n) {
      await context.webhook.post("https://api.telegram.org/botYOUR_KEY/sendMessage", {
        text: `🚨 巨鲸 Swap 告警: ${sender} 交易了 ${in0 / (10n ** 18n)} Tokens!`
      });
    }
  }
});
```

### 2. ERC-20 代币转账与黑洞销毁追踪 (`erc20_transfer.js`)
```javascript
ponder.on("ERC20:Transfer", async ({ event, context }) => {
  const { from, to, value } = event.args;
  const val = BigInt(value || "0");

  if (to === "0x0000000000000000000000000000000000000000") {
    console.log(`🔥 [Token Burn] ${val / (10n ** 18n)} Tokens 被销毁!`);
    return;
  }

  if (val >= 50000n * (10n ** 18n)) {
    await context.webhook.post("http://127.0.0.1:3000/api/alerts", { from, to, amount: val.toString() });
  }
});
```

### 3. Uniswap V3 流动性池 Swap & SSE 实时推流 (`uniswap_v3.js`)
```javascript
ponder.on("UniswapV3Pool:Swap", async ({ event, context }) => {
  const { tick, liquidity } = event.args;

  context.sse.broadcast({
    type: "UNISWAP_V3_SWAP",
    pool: event.log.address,
    tick: Number(tick),
    liquidity: liquidity.toString()
  });
});
```

---

## JSON 规则配置结构说明

单条规则包含以下字段：

| 字段 | 类型 | 说明 | 示例 |
| :--- | :--- | :--- | :--- |
| `contract` | `string` | 监听的合约名称，支持通配符 `"*"` 表示所有合约 | `"PancakePair"` / `"*"` |
| `event` | `string` | 监听的事件名称，支持通配符 `"*"` 表示所有事件 | `"Swap"` / `"Transfer"` |
| `field` | `string` | 匹配的事件字段名称 | `"amount0In"` / `"value"` |
| `op` | `string` | 匹配操作符：`"eq"`, `"gt"`, `"gte"`, `"lt"`, `"lte"`, `"always"` | `"gte"` |
| `val` | `string` | 匹配的目标比较值 | `"1000000000000000000000"` |
| `action` | `object` | 触发的业务动作，包含 `type` (`"log"` / `"webhook"`) | `{"type": "log", "msg": "..."}` |

---

## 示例清单

### 1. DEX 巨鲸交易告警 (`whale_alert.json`)
监听 PancakeSwap 上的 `Swap` 事件，当单笔交易数值超过阈值时，打印系统高优先告警，并异步发送 Webhook 至 Telegram/Discord Bot。

### 2. 代币转账与销毁监控 (`erc20_transfer_rule.json`)
监听 BUSD / ERC-20 的 `Transfer` 事件，监控 50,000+ 大额转账，以及发送至 `0x0000...0000` 黑洞地址的销毁 (Burn) 行为。

### 3. 多合约全量规则监控 (`multi_contract_rules.json`)
展示如何使用 `"*"` 通配符匹配全量链上事件，并向内部 Webhook 接收服务推送结构化 JSON 消息。

---

## 在 Zig 中加载运行 Handler 脚本

在主程序启动时，通过 `ScriptEngine` 加载脚本文件：

```zig
const std = @import("std");
const zponder = @import("zponder");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const io = std.Io.getGlobal();

    // 1. 初始化脚本引擎
    var engine = zponder.script_engine.ScriptEngine.init(alloc, io);
    defer engine.deinit();

    // 2. 动态加载 handler 脚本
    try engine.loadScriptFile("examples/handlers/whale_alert.json");

    // 3. 挂载至 Indexer
    // indexer.setEventCallback(&engine, struct {
    //     fn cb(ctx: ?*anyopaque, contract: []const u8, event: []const u8, fields: []const zponder.db.DecodedField, block: u64) void {
    //         const eng: *zponder.script_engine.ScriptEngine = @ptrCast(@alignCast(ctx.?));
    //         eng.processEvent(contract, event, fields, block);
    //     }
    // }.cb);
}
```
