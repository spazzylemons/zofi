const std = @import("std");

/// Stat a file, following symlinks.
pub fn followStatAt(dir_fd: std.os.fd_t, filename: []const u8) !std.os.Stat {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    _ = try std.fmt.bufPrintZ(&buf, "/proc/self/fd/{}/{s}", .{ dir_fd, filename });
    return try std.os.fstatatZ(dir_fd, @ptrCast([*:0]const u8, &buf), 0);
}

fn stringLessThan(context: void, p: [:0]const u8, q: [:0]const u8) bool {
    _ = context;
    return std.mem.order(u8, p, q) == .lt;
}

pub fn sortChoices(choices: [][:0]const u8) void {
    std.sort.sort([:0]const u8, choices, {}, stringLessThan);
}
