/**
 * zponder JavaScript Event Handler Example - ERC-20 Transfer & Burn Tracker
 * 
 * 监听 ERC-20 代币转账、黑洞销毁及大额变动通知
 */

ponder.on("ERC20:Transfer", async ({ event, context }) => {
  const { from, to, value } = event.args;
  const val = BigInt(value || "0");

  // 1. 监控黑洞地址销毁 (Burn)
  if (to === "0x0000000000000000000000000000000000000000") {
    console.log(`🔥 [Token Burn] Block #${event.block.number} | ${val / (10n ** 18n)} Tokens 被销毁!`);
    return;
  }

  // 2. 50,000+ 大额转账触发 Webhook POST 通知
  if (val >= 50000n * (10n ** 18n)) {
    console.warn(`💰 [大额转账] ${from} -> ${to} | 数量: ${val / (10n ** 18n)}`);
    await context.webhook.post("http://127.0.0.1:3000/api/alerts", {
      from,
      to,
      amount: val.toString(),
      txHash: event.transaction.hash,
      blockNumber: event.block.number
    });
  }
});
