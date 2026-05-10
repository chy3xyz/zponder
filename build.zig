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

    const mod = b.addModule("zponder", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zgraphql", .module = zgraphql_mod },
        },
    });
    mod.linkSystemLibrary("sqlite3", .{});
    mod.linkSystemLibrary("rocksdb", .{});
    mod.linkSystemLibrary("pq", .{});
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/lib" });
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
            },
        }),
    });

    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("rocksdb", .{});
    exe.root_module.linkSystemLibrary("pq", .{});
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/lib" });
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
