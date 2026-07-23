/**
 * zponder JavaScript Event Handler Example - Uniswap V3 Pool & SSE Streaming
 * 
 * 监听 Uniswap V3 流动性池 Swap，并通过 SSE (Server-Sent Events) 向 Web 大屏推送实时数据
 */

ponder.on("UniswapV3Pool:Swap", async ({ event, context }) => {
  const { sender, recipient, amount0, amount1, sqrtPriceX96, liquidity, tick } = event.args;

  console.log(`[Uniswap V3] Pool: ${event.log.address} | Tick: ${tick} | Liquidity: ${liquidity}`);

  // 通过 SSE (Server-Sent Events) 实时推流至 Web 大屏与看板
  context.sse.broadcast({
    type: "UNISWAP_V3_SWAP",
    pool: event.log.address,
    tick: Number(tick),
    liquidity: liquidity.toString(),
    blockNumber: event.block.number,
    txHash: event.transaction.hash
  });
});
