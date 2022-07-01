const std = @import("std");

fn pkgConfig(b: *std.build.Builder, obj: *std.build.LibExeObjStep, name: []const u8) !void {
    const data = try std.ChildProcess.exec(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--cflags", "--libs", name },
    });
    defer {
        b.allocator.free(data.stderr);
        b.allocator.free(data.stdout);
    }

    try std.io.getStdErr().writeAll(data.stderr);

    if (data.term != .Exited or data.term.Exited != 0) {
        @panic("pkg-config failed");
    }

    var it = std.mem.tokenize(u8, data.stdout[0 .. data.stdout.len - 1], " ");
    while (it.next()) |slice| {
        if (std.mem.startsWith(u8, slice, "-I")) {
            obj.addIncludePath(b.dupe(slice[2..]));
        } else if (std.mem.startsWith(u8, slice, "-l")) {
            obj.linkSystemLibrary(b.dupe(slice[2..]));
        }
    }
}

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zofi", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibC();
    try pkgConfig(b, exe, "gtk-layer-shell-0");
    try pkgConfig(b, exe, "gtk+-3.0");
    exe.single_threaded = true;
    if (b.option(bool, "strip", "Strip debug information from the binary to reduce file size")) |strip| {
        exe.strip = strip;
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
