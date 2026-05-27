const std = @import("std");

fn getGitCommit(b: *std.Build) []const u8 {
    if (!std.process.can_spawn) return "unknown";
    const argv = &.{ "git", "rev-parse", "--short", "HEAD" };
    var out_code: u8 = 0;
    const stdout = b.runAllowFail(argv, &out_code, .ignore) catch return "unknown";
    return std.mem.trimEnd(u8, stdout, "\n");
}

fn getVersionFromZon(b: *std.Build) []const u8 {
    const argv = &.{ "grep", "version", b.pathFromRoot("build.zig.zon") };
    var out_code: u8 = 0;
    const stdout = b.runAllowFail(argv, &out_code, .ignore) catch return "0.1.0";
    const trimmed = std.mem.trim(u8, stdout, " \n\r\t,");
    const prefix = ".version = \"";
    const start = std.mem.indexOf(u8, trimmed, prefix) orelse return "0.1.0";
    const rest = trimmed[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "0.1.0";
    return b.dupe(rest[0..end]);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const git_commit = b.dupe(getGitCommit(b));
    const version = getVersionFromZon(b);

    const options = b.addOptions();
    options.addOption([]const u8, "git_commit", git_commit);
    options.addOption([]const u8, "version", version);

    const zgraphql_dep = b.dependency("zgraphql", .{});
    const zgraphql_mod = zgraphql_dep.module("zgraphql");

    // Platform-aware include/lib paths.
    // Zig 0.17 errors on missing library directories, so paths must be valid.
    // macOS arm64: homebrew at /opt/homebrew; macOS x64: homebrew at /usr/local.
    const is_macos = target.result.os.tag == .macos;
    const is_arm64 = target.result.cpu.arch == .aarch64;
    const include_paths: []const []const u8 = if (is_macos) &.{
        "/opt/homebrew/include",
        "/opt/homebrew/opt/libpq/include",
        "/opt/homebrew/opt/rocksdb/include",
        "/usr/local/include",
        "/usr/local/opt/libpq/include",
        "/usr/local/opt/rocksdb/include",
    } else &.{
        "/usr/include",
    };
    // Use only the detected homebrew prefix for lib paths (Zig 0.17 rejects missing dirs).
    const lib_paths: []const []const u8 = if (is_macos and is_arm64) &.{
        "/opt/homebrew/lib",
        "/opt/homebrew/opt/libpq/lib",
        "/opt/homebrew/opt/rocksdb/lib",
    } else if (is_macos) &.{
        "/usr/local/lib",
        "/usr/local/opt/libpq/lib",
        "/usr/local/opt/rocksdb/lib",
    } else &.{
        "/usr/lib",
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
    };

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    for (include_paths) |p| {
        c_translate.addIncludePath(.{ .cwd_relative = p });
    }
    const c_mod = c_translate.createModule();

    const mod = b.addModule("zponder", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zgraphql", .module = zgraphql_mod },
            .{ .name = "c", .module = c_mod },
        },
    });
    mod.linkSystemLibrary("sqlite3", .{});
    mod.linkSystemLibrary("rocksdb", .{});
    mod.linkSystemLibrary("pq", .{});
    for (include_paths) |p| {
        mod.addIncludePath(.{ .cwd_relative = p });
    }
    for (lib_paths) |p| {
        mod.addLibraryPath(.{ .cwd_relative = p });
    }
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
    exe.root_module.linkSystemLibrary("rocksdb", .{});
    exe.root_module.linkSystemLibrary("pq", .{});
    for (include_paths) |p| {
        exe.root_module.addIncludePath(.{ .cwd_relative = p });
    }
    for (lib_paths) |p| {
        exe.root_module.addLibraryPath(.{ .cwd_relative = p });
    }
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zponder indexer");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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
