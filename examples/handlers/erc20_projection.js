/**
 * zponder JavaScript Event Handler Example - 业务投影（ponder.db）
 *
 * 演示 K 线/聚合表投影：把 ERC-20 Transfer 事件落成两张派生表。
 *  - proj_erc20_flow  逐笔明细（含链上区块时间戳 event.block.timestamp）
 *  - proj_erc20_kline 每块聚合（按区块聚合转账总额，K 线可直接消费）
 *
 * 约定（与重组回滚配合）：
 *  - 表名以 proj_ 前缀命名
 *  - 必须包含 block_number 列；重组时引擎按 block_number >= fork_point 级联删除
 *  - 建表语句放脚本顶层，加载时执行一次；写入在 ponder.on 回调内
 */

const FLOW_DDL = `
  CREATE TABLE IF NOT EXISTS proj_erc20_flow (
    block_number INTEGER NOT NULL,
    ts           INTEGER NOT NULL,
    from_addr    TEXT,
    to_addr      TEXT,
    amount       TEXT,
    PRIMARY KEY (block_number, from_addr, to_addr, amount)
  );
`;

const KLINE_DDL = `
  CREATE TABLE IF NOT EXISTS proj_erc20_kline (
    block_number INTEGER NOT NULL PRIMARY KEY,
    ts           INTEGER NOT NULL,
    total        TEXT NOT NULL,
    tx_count     INTEGER NOT NULL DEFAULT 0
  );
`;

// 顶层执行：脚本加载时建表（ponder.db 在加载前已由引擎注入）
ponder.db.exec(FLOW_DDL);
ponder.db.exec(KLINE_DDL);

ponder.on("ERC20:Transfer", (event) => {
  const { from, to, value } = event.args;
  const amount = String(BigInt(value || "0x0"));
  const bn = event.block.number;
  const ts = event.block.timestamp;

  // 1) 逐笔明细
  ponder.db.exec(
    "INSERT OR REPLACE INTO proj_erc20_flow (block_number, ts, from_addr, to_addr, amount) VALUES (?, ?, ?, ?, ?);",
    bn, ts, from, to, amount,
  );

  // 2) 每块聚合（K 线柱）：同块多笔累加
  ponder.db.exec(
    `INSERT INTO proj_erc20_kline (block_number, ts, total, tx_count)
     VALUES (?, ?, ?, 1)
     ON CONFLICT(block_number) DO UPDATE SET
       total = CAST(CAST(total AS INTEGER) + CAST(excluded.total AS INTEGER) AS TEXT),
       tx_count = tx_count + 1;`,
    bn, ts, amount,
  );
});
