# zponder 示例

## K线图 (`kline.html`)

基于链上 Swap 事件的 OHLC 聚合 + 交互式蜡烛图。

```
打开方式: 浏览器直接打开 examples/kline.html
```

### 功能
- 从 zponder `/events/:contract/:event` API 拉取 Swap 事件
- 按时间聚合为 OHLC (开高低收) 蜡烛图
- 支持 1m / 5m / 15m / 1h / 4h K线周期
- 内置 PancakeSwap BUSD/WBNB、CAKE/WBNB 预设 (BNB Chain)
- 内置 Uniswap USDC/WETH 预设 (Ethereum)
- Mock 模式 — API 不可用时自动生成演示数据
- 使用 TradingView Lightweight Charts 渲染

### 使用前提

**方式 1: 连接运行中的 zponder**

```bash
# 1. 启动 zponder 索引 PancakeSwap pair
# config.toml:
#   chain = "bsc"
#   [[contracts]]
#   name = "busd_wbnb"
#   address = "0x58f876857a02d6762e0101bb5c46a3f4e5d07bf3"
#   events = ["Swap"]

zig build run -- -c config.toml

# 2. 浏览器打开 examples/kline.html
# 3. 选择预设 "PancakeSwap BUSD/WBNB"
# 4. 点击 "加载数据"
```

**方式 2: 纯前端演示 (Mock 模式)**

直接打开 `kline.html`，无需启动 zponder。图表自动使用模拟数据渲染。

### PancakeSwap V2 Pair ABI (最小化)

索引 PancakeSwap/Uniswap V2 交易对需要以下 ABI：

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

### K线计算逻辑

```
price = (amount0In + amount0Out) / (amount1In + amount1Out)
       = token1 per token0

每个 Swap 事件:
  open  = 区间第一个 price
  high  = max(price)
  low   = min(price)
  close = 区间最后一个 price
  volume = Σ amount1
```

### 技术栈

| 组件 | 选型 |
|------|------|
| 图表库 | TradingView Lightweight Charts v5 (免费, CDN) |
| CSS | Tailwind CSS CDN |
| 框架 | 无 — 纯 vanilla JS |
| 数据源 | zponder HTTP API (带 mock fallback) |
