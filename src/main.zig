const Launcher = @import("Launcher.zig");
const std = @import("std");
const version_info = @import("version_info");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// show warnings even in release builds
pub const log_level = .warn;

fn freeKeys(map: *std.StringHashMapUnmanaged(void)) void {
    var it = map.keyIterator();
    while (it.next()) |name| {
        allocator.free(@ptrCast([:0]const u8, name.*));
    }
}

fn searchPath() ![]const [:0]const u8 {
    // get the path variable, otherwise we don't know what we can run
    const path = std.os.getenvZ("PATH") orelse return error.NoPath;
    // collect executable names here
    var map = std.StringHashMapUnmanaged(void){};
    defer map.deinit(allocator);
    errdefer freeKeys(&map);
    // iterate over each path in PATH
    var path_iterator = std.mem.split(u8, path, ":");
    while (path_iterator.next()) |dir_name| {
        // open directory in iteration mode
        var dir = std.fs.cwd().openDir(dir_name, .{ .iterate = true }) catch |err| {
            // report and move on
            std.log.warn("cannot open path directory {s}: {}", .{ dir_name, err });
            continue;
        };
        defer dir.close();
        // chcek each file in the directory
        var dir_iterator = dir.iterate();
        while (try dir_iterator.next()) |entry| {
            // follow symlinks
            var full_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ dir_name, entry.name }) catch
                return error.NameTooLong;
            var filename_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const filename = std.fs.realpathZ(full_path, &filename_buf) catch |err| {
                std.log.warn("cannot locate {s}: {}", .{ full_path, err });
                continue;
            };
            // check that it is a file and is executable
            const stat = std.os.fstatat(dir.fd, filename, 0) catch |err| {
                std.log.warn("cannot stat {s}: {}", .{ filename, err });
                continue;
            };
            if (stat.mode & std.os.S.IFMT != std.os.S.IFREG) continue;
            if (stat.mode & 0o111 == 0) continue;
            // entry is a file and executable, we will add it to the map
            if (!map.contains(entry.name)) {
                try map.ensureUnusedCapacity(allocator, 1);
                const copy = try allocator.dupeZ(u8, entry.name);
                map.putAssumeCapacity(copy, {});
            }
        }
    }
    // all executables have been collected - sort them now
    const result = try allocator.alloc([:0]const u8, map.size);
    var it = map.keyIterator();
    for (result) |*name| {
        name.* = @ptrCast([:0]const u8, it.next().?.*);
    }
    std.sort.sort([:0]const u8, result, {}, stringLessThan);
    return result;
}

fn stringLessThan(context: void, p: [:0]const u8, q: [:0]const u8) bool {
    _ = context;
    return std.mem.order(u8, p, q) == .lt;
}

pub fn main() u8 {
    defer _ = gpa.deinit();

    var width: u15 = 640;
    var height: u15 = 320;

    var args = std.process.ArgIterator.init();
    const process_name = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            std.io.getStdOut().writer().print(
                \\usage: {s} [-h] [-v] [-cw width] [-ch height]
                \\general options:
                \\  -h          display this help and exit
                \\  -v          display program information and exit
                \\configuration:
                \\  -cw width   set the width of the window (default: 640)
                \\  -ch height  set the height of the window (default: 320)
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
        } else if (std.mem.eql(u8, arg, "-cw")) {
            const value = args.next() orelse {
                std.log.err("missing value for -cw", .{});
                return 1;
            };

            width = std.fmt.parseUnsigned(u15, value, 10) catch |err| {
                std.log.err("invalid width: {}", .{err});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-ch")) {
            const value = args.next() orelse {
                std.log.err("missing value for -ch", .{});
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

    const exes = searchPath() catch |err| {
        std.log.err("failed to search path: {}", .{err});
        return 1;
    };
    defer {
        for (exes) |exe| {
            allocator.free(exe);
        }
        allocator.free(exes);
    }

    return Launcher.run(exes, width, height);
}
