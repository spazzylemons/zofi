const CommandMode = @import("modes/CommandMode.zig");
const DesktopEntryMode = @import("modes/DesktopEntryMode.zig");
const g = @import("g.zig");
const Launcher = @import("Launcher.zig");
const std = @import("std");
const version_info = @import("version_info");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub usingnamespace if (@import("builtin").is_test) struct {
    pub const TestAllocator = struct {
        backing: std.mem.Allocator = gpa.allocator(),

        pub fn allocator(self: *TestAllocator) std.mem.Allocator {
            return std.mem.Allocator.init(self, allocFn, resizeFn, freeFn);
        }

        fn allocFn(self: *TestAllocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) std.mem.Allocator.Error![]u8 {
            return self.backing.rawAlloc(len, ptr_align, len_align, ret_addr);
        }

        fn resizeFn(self: *TestAllocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) ?usize {
            return self.backing.rawResize(buf, buf_align, new_len, len_align, ret_addr);
        }

        fn freeFn(self: *TestAllocator, buf: []u8, buf_align: u29, ret_addr: usize) void {
            return self.backing.rawFree(buf, buf_align, ret_addr);
        }
    };

    pub var test_allocator = TestAllocator{};
    pub const allocator = test_allocator.allocator();
} else struct {
    pub const allocator = gpa.allocator();
};

// show warnings even in release builds
pub const log_level = if (std.log.default_level == .err)
    .warn
else
    std.log.default_level;

const ModeChoice = enum {
    command,
    desktop,
};

pub fn main() u8 {
    defer _ = gpa.deinit();

    var width: u15 = 640;
    var height: u15 = 320;
    var mode: ModeChoice = .command;

    var args = std.process.ArgIterator.init();
    const process_name = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            std.io.getStdOut().writer().print(
                \\usage: {s} [-h] [-v] [-m mode] [-sx width] [-sy height]
                \\general options:
                \\  -h          display this help and exit
                \\  -v          display program information and exit
                \\  -m mode     change the operating mode (default: command)
                \\modes:
                \\  command     run commands directly
                \\  desktop     run desktop applications
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
        } else if (std.mem.eql(u8, arg, "-m")) {
            const value = args.next() orelse {
                std.log.err("missing value for -m", .{});
                return 1;
            };

            mode = std.meta.stringToEnum(ModeChoice, value) orelse {
                std.log.err("invalid mode", .{});
                return 1;
            };
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

    // pre-initialize gtk here, so we can have the locale loaded
    var dummy_argc = if (process_name != null) @as(c_int, 1) else @as(c_int, 0);
    var dummy_argv_value = [_:null]?[*:0]u8{ if (process_name != null) std.os.argv[0] else null, null };
    var dummy_argv: ?[*:null]?[*:0]u8 = &dummy_argv_value;
    _ = g.c.gtk_init(&dummy_argc, &dummy_argv);

    switch (mode) {
        .command => {
            var command_mode = CommandMode.init() catch |err| {
                std.log.err("failed to search path: {}", .{err});
                return 1;
            };
            defer command_mode.deinit();
            return Launcher.run(&command_mode.mode, width, height);
        },

        .desktop => {
            var desktop_mode = DesktopEntryMode.init() catch |err| {
                std.log.err("failed to read desktop files: {}", .{err});
                return 1;
            };
            defer desktop_mode.deinit();
            return Launcher.run(&desktop_mode.mode, width, height);
        },
    }
}

test {
    std.testing.refAllDecls(DesktopEntryMode);
}
