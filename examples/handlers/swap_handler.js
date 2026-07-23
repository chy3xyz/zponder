/**
 * zponder JavaScript Event Handler Example - DEX Swap Processing
 * 
 * 监听 PancakeSwap/Uniswap Swap 事件，计算交易价格与点差并触发告警
 */

ponder.on("PancakePair:Swap", async ({ event, context }) => {
  const { sender, amount0In, amount1In, amount0Out, amount1Out, to } = event.args;
  const blockNumber = event.block.number;

  const in0 = BigInt(amount0In || "0");
  const out1 = BigInt(amount1Out || "0");

  if (in0 > 0n && out1 > 0n) {
    const price = Number(out1) / Number(in0);
    console.log(`[DEX Swap] Block #${blockNumber} | Sender: ${sender} | Price: ${price.toFixed(6)}`);

    // 触发巨鲸告警 (当输入 Token0 数量大于 100 单位时)
    if (in0 >= 100000000000000000000n) {
      await context.webhook.post("https://api.telegram.org/botYOUR_KEY/sendMessage", {
        text: `🚨 巨鲸 Swap 告警 @ Block #${blockNumber}: ${sender} 交易了 ${in0 / (10n ** 18n)} Tokens!`
      });
    }
  }
});
