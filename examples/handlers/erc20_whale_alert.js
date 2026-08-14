/**
 * ERC20 大额转账监控 —— 鲸鱼告警（JS handler 版）
 *
 * 配置（config.toml）：
 *   [[contracts]]
 *   name = "USDC"                    # 代币名（与 ponder.on 第一个词对应）
 *   address = "0x..."               # USDC 合约地址
 *   abi_path = "./abis/erc20.abi"
 *   events = ["Transfer"]
 *   # 可选：只索引大额转账，节省 RPC 与存储成本
 *   filters = ["Transfer:value:gte:1000000000000"]   # 100 万 USDC（6 位小数）
 *
 * Transfer 事件签名：
 *   Transfer(address indexed from, address indexed to, uint256 value)
 */
ponder.on("USDC:Transfer", (event) => {
  const { from, to, value } = event.args;
  const blockNumber = event.block.number;

  // USDC 6 位小数：1 万 USDC = 10_000 * 10^6
  const amount = BigInt(value || "0x0");
  const decimals = 6n;
  const usdAmount = amount / (10n ** decimals);

  // 铸币/销毁（from 或 to 是零地址）
  if (from === "0x0000000000000000000000000000000000000000") {
    console.log(`[USDC] 区块 ${blockNumber} | 铸币 ${usdAmount} USDC -> ${to.slice(0, 10)}`);
    return;
  }
  if (to === "0x0000000000000000000000000000000000000000") {
    console.log(`[USDC] 区块 ${blockNumber} | 销毁 ${usdAmount} USDC <- ${from.slice(0, 10)}`);
    return;
  }

  // 大额转账告警
  if (usdAmount >= 100000n) {
    console.log(`🐋 [USDC] 区块 ${blockNumber} | 鲸鱼转账 ${usdAmount.toLocaleString()} USDC: ${from.slice(0, 10)} -> ${to.slice(0, 10)}`);
  } else {
    console.log(`[USDC] 区块 ${blockNumber} | ${usdAmount} USDC: ${from.slice(0, 10)} -> ${to.slice(0, 10)}`);
  }
});
