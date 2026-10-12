const std = @import("std");

fn getGitCommit(b: *std.Build) []const u8 {
    if (!std.process.can_spawn) return "unknown";
    const argv = &.{ "git", "rev-parse", "--short", "HEAD" };
    var out_code: u8 = 0;
    const stdout = b.runAllowFail(argv, &out_code, .ignore) catch return "unknown";
    return std.mem.trimEnd(u8, stdout, "\n");
}

fn getVersionFromZon(b: *std.Build) []const u8 {
    const argv = &.{ "grep", "version", "build.zig.zon" };
    var out_code: u8 = 0;
    const stdout = b.runAllowFail(argv, &out_code, .ignore) catch return "0.1.0";
    const trimmed = std.mem.trim(u8, stdout, " \n\r\t,");
    const prefix = ".version = \"";
    const start = std.mem.indexOf(u8, trimmed, prefix) orelse return "0.1.0";
    const rest = trimmed[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "0.1.0";
    return b.dupe(rest[0..end]);
}

/// 条件路径表按需加入编译单元：`anytype` 同时适配 TranslateC 与 Module
/// （两者都有 `addIncludePath`；`addLibraryPath` 只有 Module 有）。
fn addIncludePaths(compile: anytype, paths: []const []const u8) void {
    for (paths) |p| compile.addIncludePath(.{ .cwd_relative = p });
}

fn addLibraryPaths(compile: *std.Build.Module, paths: []const []const u8) void {
    for (paths) |p| compile.addLibraryPath(.{ .cwd_relative = p });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const git_commit = b.dupe(getGitCommit(b));
    const version = getVersionFromZon(b);

    const options = b.addOptions();
    options.addOption([]const u8, "git_commit", git_commit);
    options.addOption([]const u8, "version", version);

    // 发布二进制不许动态依赖 librocksdb / libpq（干净机器上根本没有这两个库，
    // 实测 npm 包在缺 brew rocksdb 的机器上直接 dyld 失败），故两条后端做成可选特性。
    // 关闭时由 *_stub.zig 顶替真实实现，并在打开该后端时明确报错。
    const rocksdb = b.option(bool, "rocksdb", "编译 RocksDB 后端（关闭后不再链接 librocksdb）") orelse true;
    const postgres = b.option(bool, "postgres", "编译 PostgreSQL 后端（关闭后不再链接 libpq）") orelse true;
    options.addOption(bool, "rocksdb", rocksdb);
    options.addOption(bool, "postgres", postgres);

    const zgraphql_dep = b.dependency("zgraphql", .{});
    const zgraphql_mod = zgraphql_dep.module("zgraphql");

    // Platform-aware include/lib paths.
    // Zig 0.17 errors on missing library directories, so paths must be valid ——
    // 可选后端的路径**必须**跟着特性一起条件化，否则关掉后端时这些目录不存在会直接报错。
    // macOS arm64: homebrew at /opt/homebrew; macOS x64: homebrew at /usr/local.
    const is_macos = target.result.os.tag == .macos;
    const is_arm64 = target.result.cpu.arch == .aarch64;
    const include_paths: []const []const u8 = if (is_macos) &.{
        "/opt/homebrew/include",
        "/usr/local/include",
    } else &.{
        "/usr/include",
    };
    const rocksdb_include_paths: []const []const u8 = if (is_macos) &.{
        "/opt/homebrew/opt/rocksdb/include",
        "/usr/local/opt/rocksdb/include",
    } else &.{};
    const pg_include_paths: []const []const u8 = if (is_macos) &.{
        "/opt/homebrew/opt/libpq/include",
        "/usr/local/opt/libpq/include",
    } else &.{
        // Debian/Ubuntu 的 libpq 头文件位于 /usr/include/postgresql/
        "/usr/include/postgresql",
    };
    // Use only the detected homebrew prefix for lib paths (Zig 0.17 rejects missing dirs).
    const lib_paths: []const []const u8 = if (is_macos and is_arm64) &.{
        "/opt/homebrew/lib",
    } else if (is_macos) &.{
        "/usr/local/lib",
    } else &.{
        "/usr/lib",
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
    };
    const rocksdb_lib_paths: []const []const u8 = if (is_macos and is_arm64) &.{
        "/opt/homebrew/opt/rocksdb/lib",
    } else if (is_macos) &.{
        "/usr/local/opt/rocksdb/lib",
    } else &.{};
    const pg_lib_paths: []const []const u8 = if (is_macos and is_arm64) &.{
        "/opt/homebrew/opt/libpq/lib",
    } else if (is_macos) &.{
        "/usr/local/opt/libpq/lib",
    } else &.{};

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c_translate.addIncludePath(b.path("src"));
    addIncludePaths(c_translate, include_paths);
    if (rocksdb) addIncludePaths(c_translate, rocksdb_include_paths);
    if (postgres) addIncludePaths(c_translate, pg_include_paths);
    // c.h 用这两个宏守卫可选后端的 include；关闭时头文件不必存在。
    c_translate.defineCMacro("ZPONDER_ROCKSDB", if (rocksdb) "1" else "0");
    c_translate.defineCMacro("ZPONDER_POSTGRES", if (postgres) "1" else "0");
    const c_mod = c_translate.createModule();

    const qjs_flags = &.{"-D_GNU_SOURCE"};

    const mod = b.addModule("zponder", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "zgraphql", .module = zgraphql_mod },
            .{ .name = "c", .module = c_mod },
        },
    });
    mod.addCSourceFiles(.{
        .files = &.{
            "src/quickjs/quickjs.c",
            "src/quickjs/libregexp.c",
            "src/quickjs/libunicode.c",
            "src/quickjs/dtoa.c",
        },
        .flags = qjs_flags,
    });
    mod.linkSystemLibrary("sqlite3", .{});
    if (rocksdb) mod.linkSystemLibrary("rocksdb", .{});
    if (postgres) mod.linkSystemLibrary("pq", .{});
    addIncludePaths(mod, include_paths);
    if (rocksdb) addIncludePaths(mod, rocksdb_include_paths);
    if (postgres) addIncludePaths(mod, pg_include_paths);
    addLibraryPaths(mod, lib_paths);
    if (rocksdb) addLibraryPaths(mod, rocksdb_lib_paths);
    if (postgres) addLibraryPaths(mod, pg_lib_paths);
    mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zponder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zponder", .module = mod },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "zgraphql", .module = zgraphql_mod },
                .{ .name = "c", .module = c_mod },
            },
        }),
    });

    exe.root_module.linkSystemLibrary("sqlite3", .{});
    if (rocksdb) exe.root_module.linkSystemLibrary("rocksdb", .{});
    if (postgres) exe.root_module.linkSystemLibrary("pq", .{});
    addIncludePaths(exe.root_module, include_paths);
    if (rocksdb) addIncludePaths(exe.root_module, rocksdb_include_paths);
    if (postgres) addIncludePaths(exe.root_module, pg_include_paths);
    addLibraryPaths(exe.root_module, lib_paths);
    if (rocksdb) addLibraryPaths(exe.root_module, rocksdb_lib_paths);
    if (postgres) addLibraryPaths(exe.root_module, pg_lib_paths);
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zponder indexer");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());



    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
