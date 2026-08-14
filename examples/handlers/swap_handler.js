/**
 * zponder JavaScript Event Handler Example - DEX Swap Processing
 *
 * 监听 PancakeSwap/Uniswap Swap 事件，计算交易价格
 * 更完整的版本见 dex_swap_monitor.js
 */

ponder.on("PancakePair:Swap", (event) => {
  const { sender, amount0In, amount1In, amount0Out, amount1Out, to } = event.args;
  const blockNumber = event.block.number;

  // uint 参数是 hex 字符串，用 BigInt 解析
  const in0 = BigInt(amount0In || "0x0");
  const out1 = BigInt(amount1Out || "0x0");

  if (in0 > 0n && out1 > 0n) {
    const price = Number(out1) / Number(in0);
    console.log(`[DEX Swap] Block #${blockNumber} | Sender: ${sender} | Price: ${price.toFixed(6)}`);

    // 大额交易提示（webhook 推送见 whale_alert.json 声明式规则）
    if (in0 >= 100000000000000000000n) {
      console.log(`🚨 巨鲸 Swap @ Block #${blockNumber}: ${sender} 交易了 ${in0 / (10n ** 18n)} Tokens!`);
    }
  }
});
