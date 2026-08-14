/**
 * zponder JavaScript Event Handler Example - Uniswap V3 Pool
 *
 * 监听 Uniswap V3 流动性池 Swap 事件。
 * 实时推流无需 handler 手动广播 —— zponder 自动通过 SSE (/stream) 推送所有索引到的事件。
 */

ponder.on("UniswapV3Pool:Swap", (event) => {
  const { sender, recipient, amount0, amount1, sqrtPriceX96, liquidity, tick } = event.args;
  const blockNumber = event.block.number;

  console.log(`[Uniswap V3] Block #${blockNumber} | Tick: ${tick} | Liquidity: ${BigInt(liquidity || "0x0")}`);
  console.log(`  sender=${sender} recipient=${recipient} amount0=${BigInt(amount0 || "0x0")} amount1=${BigInt(amount1 || "0x0")}`);

  // 该 Swap 会自动出现在 SSE 流（GET /stream）中，客户端无需额外代码即可订阅
});
