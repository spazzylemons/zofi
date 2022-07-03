//! A mode that executes commands.

const allocator = @import("../main.zig").allocator;
const Mode = @import("../Mode.zig");
const std = @import("std");
const util = @import("../util.zig");

const CommandMode = @This();

/// The mode structure.
mode: Mode,

pub fn init() !CommandMode {
    return CommandMode{
        .mode = .{
            .choices = try searchPath(),
            .custom_allowed = true,
            .executeFn = execute,
        },
    };
}

pub fn deinit(self: CommandMode) void {
    for (self.mode.choices) |choice| {
        allocator.free(choice);
    }
    allocator.free(self.mode.choices);
}

fn execute(mode: *Mode, choice: [*:0]const u8) void {
    _ = mode;
    const pid = std.os.fork() catch |err| {
        std.log.err("failed to fork process: {}", .{err});
        return;
    };

    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", choice, null };
        const err = std.os.execveZ("/bin/sh", &argv, std.c.environ);
        std.log.err("failed to exec process: {}", .{err});
        std.os.exit(1);
    }
}

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
            // check that it is a file and is executable
            const stat = util.followStatAt(dir.fd, entry.name) catch |err| {
                std.log.warn("cannot stat {s}: {}", .{ entry.name, err });
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
    util.sortChoices(result);
    return result;
}
