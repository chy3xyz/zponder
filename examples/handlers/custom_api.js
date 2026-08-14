/**
 * 自定义 HTTP API —— ponder.http + middleware（Hono 风格）
 *
 * 无需额外配置，脚本放入 ./handlers/ 即自动生效。
 * 端点挂在 zponder 的 HTTP 服务（config.toml 的 [http] port，默认 8080）上。
 *
 * 示例：
 *   curl "http://localhost:8080/api/health?api_key=secret123"
 *   curl "http://localhost:8080/api/ping"
 *
 * 说明：ponder.http 适合自定义轻量接口（鉴权、健康检查、参数回显、计算）。
 * 索引数据查询请用内置 REST（/events/...）或 GraphQL（/graphql）。
 */

// 全局中间件：API key 鉴权（只有 /api/ 前缀需要）
ponder.http.use((c, next) => {
  const key = c.req.query("api_key");
  if (key !== "secret123") {
    c.status(401);
    return c.json({ error: "invalid api_key" });
  }
  next();
});

// 健康检查
ponder.http.get("/api/health", (c) => {
  return c.json({ status: "ok", service: "zponder", time: Date.now() });
});

// 免鉴权的 ping（未加中间件保护 —— 但 use 是全局的，此例仅为演示）
ponder.http.get("/api/ping", (c) => {
  return c.text("pong");
});

// 路径参数 + 计算类接口
ponder.http.get("/api/wei/:amount", (c) => {
  const wei = c.req.param("amount");
  const eth = Number(wei) / 1e18;
  return c.json({ wei: wei, eth: eth.toFixed(6) });
});

// POST 回显（演示 body 访问）
ponder.http.post("/api/echo", (c) => {
  return c.json({ received: c.req.body() });
});
