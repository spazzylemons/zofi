const CommandMode = @import("modes/CommandMode.zig");
const Launcher = @import("Launcher.zig");
const std = @import("std");
const version_info = @import("version_info");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

// show warnings even in release builds
pub const log_level = .warn;

pub fn main() u8 {
    defer _ = gpa.deinit();

    var width: u15 = 640;
    var height: u15 = 320;

    var args = std.process.ArgIterator.init();
    const process_name = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            std.io.getStdOut().writer().print(
                \\usage: {s} [-h] [-v] [-sx width] [-sy height]
                \\general options:
                \\  -h          display this help and exit
                \\  -v          display program information and exit
                \\configuration:
                \\  -sx width   set the width of the window (default: 640)
                \\  -sy height  set the height of the window (default: 320)
                \\
            , .{process_name.?}) catch return 1;
            return 0;
        } else if (std.mem.eql(u8, arg, "-v")) {
            std.io.getStdOut().writer().print(
                \\zofi version {s} (commit {s})
                \\copyright (c) 2022 spazzylemons
                \\license: MIT <https://opensource.org/licenses/MIT>
                \\source: <https://github.com/spazzylemons/zofi>
                \\
            , .{ version_info.version, version_info.commit_hash }) catch return 1;
            return 0;
        } else if (std.mem.eql(u8, arg, "-sx")) {
            const value = args.next() orelse {
                std.log.err("missing value for -sx", .{});
                return 1;
            };

            width = std.fmt.parseUnsigned(u15, value, 10) catch |err| {
                std.log.err("invalid width: {}", .{err});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-sy")) {
            const value = args.next() orelse {
                std.log.err("missing value for -sy", .{});
                return 1;
            };

            height = std.fmt.parseUnsigned(u15, value, 10) catch |err| {
                std.log.err("invalid height: {}", .{err});
                return 1;
            };
        } else {
            std.log.err("invalid argument: {s}", .{arg});
            return 1;
        }
    }

    // guard against signed integer overflow within gtk
    // does not protect against the possibility of out-of-memory
    // TODO should the limits be halved to account for HiDPI displays?
    if (@as(u32, width) * @as(u32, height) * 4 > std.math.maxInt(u31)) {
        std.log.err("window dimensions too large", .{});
        return 1;
    }

    var command_mode = CommandMode.init() catch |err| {
        std.log.err("failed to search path: {}", .{err});
        return 1;
    };
    defer command_mode.deinit();

    return Launcher.run(&command_mode.mode, width, height);
}
