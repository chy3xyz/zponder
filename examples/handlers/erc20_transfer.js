/**
 * zponder JavaScript Event Handler Example - ERC-20 Transfer & Burn Tracker
 *
 * 监听 ERC-20 代币转账、黑洞销毁及大额变动。
 * webhook 推送见 whale_alert.json（声明式规则）。
 */

ponder.on("ERC20:Transfer", (event) => {
  const { from, to, value } = event.args;
  // uint 参数是 hex 字符串，用 BigInt 解析
  const val = BigInt(value || "0x0");

  // 1. 监控黑洞地址销毁 (Burn)
  if (to === "0x0000000000000000000000000000000000000000") {
    console.log(`🔥 [Token Burn] Block #${event.block.number} | ${val / (10n ** 18n)} Tokens 被销毁!`);
    return;
  }

  // 2. 50,000+ 大额转账记录（推送用 JSON 规则或 ponder.http）
  if (val >= 50000n * (10n ** 18n)) {
    console.log(`💰 [大额转账] Block #${event.block.number} | ${from} -> ${to} | 数量: ${val / (10n ** 18n)}`);
  }
});
