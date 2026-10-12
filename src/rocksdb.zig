//! RocksDB 后端入口：按构建特性在真实实现与 stub 之间编译期分发。
//! 关闭 `-Drocksdb` 时 `rocksdb_impl.zig` 不会被分析（进而不会引用 `c.rocksdb_*`），
//! 所以目标机上不需要装 librocksdb。
const build_options = @import("build_options");

const impl = if (build_options.rocksdb) @import("rocksdb_impl.zig") else @import("rocksdb_stub.zig");

pub const Client = impl.Client;
pub const WriteBatch = impl.WriteBatch;
pub const Iterator = impl.Iterator;
