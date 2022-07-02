const std = @import("std");

fn runCommand(b: *std.build.Builder, argv: []const []const u8) []u8 {
    const cmd = std.ChildProcess.exec(.{
        .allocator = b.allocator,
        .argv = argv,
    }) catch unreachable;
    defer b.allocator.free(cmd.stdout);
    defer b.allocator.free(cmd.stderr);

    std.io.getStdErr().writeAll(cmd.stderr) catch {};

    if (cmd.term != .Exited or cmd.term.Exited != 0) {
        std.debug.panic("{s} did not exit successfully", .{argv[0]});
    }

    return b.dupe(cmd.stdout[0 .. cmd.stdout.len - 1]);
}

fn pkgConfig(b: *std.build.Builder, obj: *std.build.LibExeObjStep, name: []const u8) void {
    const args = runCommand(b, &.{ "pkg-config", "--cflags", "--libs", name });
    defer b.allocator.free(args);

    var it = std.mem.tokenize(u8, args, " ");
    while (it.next()) |slice| {
        if (std.mem.startsWith(u8, slice, "-I")) {
            obj.addIncludePath(b.dupe(slice[2..]));
        } else if (std.mem.startsWith(u8, slice, "-l")) {
            obj.linkSystemLibrary(b.dupe(slice[2..]));
        }
    }
}

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zofi", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibC();
    pkgConfig(b, exe, "gtk-layer-shell-0");
    pkgConfig(b, exe, "gtk+-3.0");
    exe.single_threaded = true;
    // allow choosing to strip binary
    if (b.option(bool, "strip", "Strip debug information from the binary to reduce file size")) |strip| {
        exe.strip = strip;
    }
    // get short git commit hash for version info
    const hash = runCommand(b, &.{ "git", "rev-parse", "--short", "HEAD" });
    defer b.allocator.free(hash);

    // provide version information to source code
    const version_info = b.addOptions();
    version_info.addOption([]const u8, "commit_hash", hash);
    version_info.addOption([]const u8, "version", "0.1.0");
    exe.addOptions("version_info", version_info);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
