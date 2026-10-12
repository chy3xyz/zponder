#include <sqlite3.h>
#include "quickjs/quickjs.h"

// 可选后端：宏由 build.zig 的 -Drocksdb / -Dpostgres 决定（未定义时按开启处理，
// 保证 IDE / 手工 translate-c 不受影响）。
#ifndef ZPONDER_ROCKSDB
#define ZPONDER_ROCKSDB 1
#endif
#ifndef ZPONDER_POSTGRES
#define ZPONDER_POSTGRES 1
#endif

#if ZPONDER_ROCKSDB
#include <rocksdb/c.h>
#endif

#if ZPONDER_POSTGRES
#include <libpq-fe.h>
#endif
