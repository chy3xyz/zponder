//! PostgreSQL 后端入口：按构建特性在真实实现与 stub 之间编译期分发。
//! 关闭 `-Dpostgres` 时 `pg_impl.zig` 不会被分析（进而不会引用 `c.PQ*`），
//! 所以目标机上不需要装 libpq。
const build_options = @import("build_options");

const impl = if (build_options.postgres) @import("pg_impl.zig") else @import("pg_stub.zig");

pub const Client = impl.Client;
pub const PgResult = impl.PgResult;
