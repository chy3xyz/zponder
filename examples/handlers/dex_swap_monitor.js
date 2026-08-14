/**
 * DEX Swap 价格监控 —— Uniswap V2 / PancakeSwap 风格交易对
 *
 * 配置（config.toml）：
 *   [[contracts]]
 *   name = "UsdcEthPair"            # 交易对名（与 ponder.on 的第一个词对应）
 *   address = "0x..."               # 交易对合约地址
 *   abi_path = "./abis/pair.abi"    # 含 Swap 事件的 ABI
 *   events = ["Swap"]
 *
 * Swap 事件签名（Uniswap V2）：
 *   Swap(address indexed sender, uint amount0In, uint amount1In,
 *        uint amount0Out, uint amount1Out, address indexed to)
 */
ponder.on("UsdcEthPair:Swap", (event) => {
  // event.args 里 uint 值是 hex 字符串（如 "0xde0b6b3a7640000"），用 BigInt 解析
  const { sender, amount0In, amount1In, amount0Out, amount1Out } = event.args;
  const blockNumber = event.block.number;

  const in0 = BigInt(amount0In || "0x0");
  const in1 = BigInt(amount1In || "0x0");
  const out0 = BigInt(amount0Out || "0x0");
  const out1 = BigInt(amount1Out || "0x0");

  // 判断方向并计算价格（amount0 是 USDC 6 位，amount1 是 ETH 18 位）
  if (in0 > 0n && out1 > 0n) {
    // 买入 ETH：USDC -> ETH
    const price = (Number(in0) / 1e6) / (Number(out1) / 1e18);
    console.log(`[DEX] 区块 ${blockNumber} | ${sender.slice(0, 10)} 以 $${price.toFixed(2)} 买入 ETH`);
  } else if (in1 > 0n && out0 > 0n) {
    // 卖出 ETH：ETH -> USDC
    const price = (Number(out0) / 1e6) / (Number(in1) / 1e18);
    console.log(`[DEX] 区块 ${blockNumber} | ${sender.slice(0, 10)} 以 $${price.toFixed(2)} 卖出 ETH`);
  }
});
