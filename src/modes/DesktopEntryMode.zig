//! A mode that executes desktop entries.

const allocator = @import("../main.zig").allocator;
const Mode = @import("../Mode.zig");
const std = @import("std");
const util = @import("../util.zig");

const DesktopEntryMode = @This();

const Map = std.StringHashMapUnmanaged(DesktopCommand);

/// The mode structure.
mode: Mode,
/// The mapping from name to command.
map: Map = .{},

fn getLocale() Locale {
    const c = @cImport(@cInclude("locale.h"));
    if (c.setlocale(c.LC_MESSAGES, null)) |l| {
        return Locale.parse(std.mem.span(l));
    } else {
        std.log.warn("failed to get locale, default locale will be used", .{});
        return Locale.parse("C");
    }
}

fn freeMap(map: *Map) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(@ptrCast([:0]const u8, entry.key_ptr.*));
        entry.value_ptr.deinit();
    }
    map.deinit(allocator);
}

const Entry = struct {
    key: []const u8,
    locale: ?[]const u8 = null,
    value: []const u8,
};

const Line = union(enum) {
    GroupHeader: []const u8,
    Entry: Entry,
};

const Locale = struct {
    lang: []const u8,
    country: ?[]const u8,
    modifier: ?[]const u8,

    fn parse(locale: []const u8) Locale {
        var country_start = std.mem.indexOfScalar(u8, locale, '_');
        var encoding_start = std.mem.indexOfScalarPos(u8, locale, country_start orelse 0, '.');
        var modifier_start = std.mem.indexOfScalarPos(u8, locale, encoding_start orelse country_start orelse 0, '@');
        var lang_end = country_start orelse encoding_start orelse modifier_start orelse locale.len;
        var country_end = encoding_start orelse modifier_start orelse locale.len;

        var lang = locale[0..lang_end];
        var country = if (country_start) |v| locale[v..country_end] else null;
        var modifier = if (modifier_start) |v| locale[v..] else null;

        return .{
            .lang = lang,
            .country = country,
            .modifier = modifier,
        };
    }

    fn matchLevel(self: Locale) u8 {
        if (self.country != null) {
            if (self.modifier != null) {
                return 4;
            } else {
                return 3;
            }
        } else if (self.modifier != null) {
            return 2;
        } else {
            return 1;
        }
    }

    fn equal(self: Locale, other: Locale) bool {
        if (!std.mem.eql(u8, self.lang, other.lang)) return false;
        if (other.country) |c| {
            if (!std.mem.eql(u8, c, self.country orelse return false)) return false;
        }
        if (other.modifier) |m| {
            if (!std.mem.eql(u8, m, self.modifier orelse return false)) return false;
        }
        return true;
    }
};

const DesktopCommand = struct {
    exec: []const [:0]const u8,
    path: ?[]const u8,

    fn deinit(self: DesktopCommand) void {
        for (self.exec) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.exec);
        if (self.path) |path| {
            allocator.free(path);
        }
    }
};

const DesktopEntry = struct {
    name: [:0]const u8,
    command: DesktopCommand,

    fn deinit(self: DesktopEntry) void {
        allocator.free(self.name);
        self.command.deinit();
    }
};

fn parseLine(line: []const u8) !?Line {
    // ignore comments
    if (line.len == 0 or line[0] == '#') return null;
    // check what this line is
    if (line[0] == '[') {
        if (line[line.len - 1] != ']') {
            return error.SyntaxError;
        }
        const name = line[1 .. line.len - 1];
        return Line{ .GroupHeader = name };
    } else {
        var key_length: usize = 0;
        var value_start: usize = undefined;
        var locale_start: ?usize = null;
        var locale: ?[]const u8 = null;
        const done = for (line) |byte, i| {
            if (locale != null) {
                if (byte != '=') return error.SyntaxError;
                value_start = i + 1;
                break true;
            } else if (locale_start) |start| {
                if (byte == ']') {
                    locale = line[start..i];
                }
            } else {
                switch (byte) {
                    'A'...'Z', 'a'...'z', '9'...'9', '-' => {
                        key_length += 1;
                    },
                    '=' => {
                        value_start = key_length + 1;
                        break true;
                    },
                    '[' => {
                        locale_start = key_length + 1;
                    },
                    else => return error.SyntaxError,
                }
            }
        } else false;
        if (!done) return error.SyntaxError;
        const key = line[0..key_length];
        const value = line[value_start..];
        return Line{ .Entry = .{
            .key = key,
            .locale = locale,
            .value = value,
        } };
    }
}

fn escapeString(string: []const u8) ![]u8 {
    var result = try std.ArrayListUnmanaged(u8).initCapacity(allocator, string.len);
    defer result.deinit(allocator);

    var in_escape = false;
    for (string) |c| {
        if (in_escape) {
            const char: u8 = switch (c) {
                's' => ' ',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => return error.SyntaxError,
            };
            result.appendAssumeCapacity(char);
            in_escape = false;
        } else if (c == '\\') {
            try result.ensureUnusedCapacity(allocator, 1);
            in_escape = true;
        } else {
            result.appendAssumeCapacity(c);
        }
    }

    if (in_escape) return error.SyntaxError;
    return result.toOwnedSlice(allocator);
}

const MatchEntry = struct {
    value: ?[]const u8 = null,
    level: u8 = 0,

    fn deinit(self: MatchEntry) void {
        if (self.value) |v| allocator.free(v);
    }
};

fn freeArgs(args: *std.ArrayListUnmanaged([:0]const u8)) void {
    for (args.items) |item| allocator.free(item);
    args.deinit(allocator);
}

fn addBufToArgs(buf: *std.ArrayListUnmanaged(u8), args: *std.ArrayListUnmanaged([:0]const u8)) !void {
    const copy = try allocator.dupeZ(u8, buf.items);
    errdefer allocator.free(copy);
    try args.append(allocator, copy);
    buf.clearRetainingCapacity();
}

fn separateArgs(buf: *std.ArrayListUnmanaged(u8), exec: []const u8) !std.ArrayListUnmanaged([:0]const u8) {
    var args = std.ArrayListUnmanaged([:0]const u8){};
    errdefer freeArgs(&args);
    var in_quote = false;
    var in_escape = false;
    for (exec) |char| {
        if (in_quote) {
            if (in_escape) {
                try buf.append(allocator, char);
                in_escape = false;
            } else if (char == '\\') {
                in_escape = true;
            } else if (char == '"') {
                if (in_escape) return error.SyntaxError;
                try addBufToArgs(buf, &args);
                in_quote = false;
            } else {
                try buf.append(allocator, char);
            }
        } else if (char == ' ') {
            if (buf.items.len > 0) {
                try addBufToArgs(buf, &args);
            }
        } else {
            try buf.append(allocator, char);
        }
    }
    if (in_quote) {
        return error.SyntaxError;
    } else if (buf.items.len > 0) {
        try addBufToArgs(buf, &args);
    }
    return args;
}

const MatchEntries = struct {
    type: MatchEntry = .{},
    name: MatchEntry = .{},
    icon: MatchEntry = .{},
    exec: MatchEntry = .{},
    path: MatchEntry = .{},

    fn deinit(self: MatchEntries) void {
        self.type.deinit();
        self.name.deinit();
        self.icon.deinit();
        self.exec.deinit();
        self.path.deinit();
    }
};

fn parseEntry(locale: Locale, entry: Entry, entries: *MatchEntries) !void {
    const match_entry = if (std.mem.eql(u8, entry.key, "Type"))
        &entries.type
    else if (std.mem.eql(u8, entry.key, "Name"))
        &entries.name
    else if (std.mem.eql(u8, entry.key, "Icon"))
        &entries.icon
    else if (std.mem.eql(u8, entry.key, "Exec"))
        &entries.exec
    else if (std.mem.eql(u8, entry.key, "Path"))
        &entries.path
    else
        return;

    if (entry.locale) |l| {
        const other = Locale.parse(l);
        if (!locale.equal(other)) return;
        const level = other.matchLevel();
        if (level < match_entry.level) return;
        match_entry.level = level;
    }

    if (match_entry.value) |v| {
        allocator.free(v);
        match_entry.value = null;
    }

    match_entry.value = try escapeString(entry.value);
}

fn parseEntries(buf: *std.ArrayListUnmanaged(u8), locale: Locale, file: std.fs.File) !MatchEntries {
    var result = MatchEntries{};
    errdefer result.deinit();

    var seen_line = false;

    while (true) {
        const byte = file.reader().readByte() catch |err| switch (err) {
            error.EndOfStream => if (buf.items.len != 0) {
                return error.SyntaxError;
            } else {
                break;
            },
            else => |e| return e,
        };

        if (byte == '\n') {
            if (try parseLine(buf.items)) |line| {
                if (line == .GroupHeader) {
                    if (!std.mem.eql(u8, line.GroupHeader, "Desktop Entry")) {
                        if (!seen_line) return error.SyntaxError;
                        break;
                    }
                    seen_line = true;
                } else if (!seen_line) {
                    return error.SyntaxError;
                } else {
                    try parseEntry(locale, line.Entry, &result);
                }
            }
            buf.clearRetainingCapacity();
        } else {
            try buf.append(allocator, byte);
        }
    }

    buf.clearRetainingCapacity();
    return result;
}

const FieldCodeExpander = struct {
    index: usize = 0,
    args: *std.ArrayListUnmanaged([:0]const u8),

    fn replace(self: *FieldCodeExpander, new_args: []const []const u8) !void {
        allocator.free(self.args.orderedRemove(self.index));
        for (new_args) |arg| {
            const copy = try allocator.dupeZ(u8, arg);
            errdefer allocator.free(copy);
            try self.args.insert(allocator, self.index, copy);
            self.index += 1;
        }
    }

    fn expand(self: *FieldCodeExpander, entries: MatchEntries) !void {
        while (self.index < self.args.items.len) {
            if (std.mem.eql(u8, self.args.items[self.index], "%i")) {
                if (entries.icon.value) |icon| {
                    try self.replace(&.{ "--icon", icon });
                } else {
                    try self.replace(&.{});
                }
            } else if (std.mem.eql(u8, self.args.items[self.index], "%c")) {
                try self.replace(&.{entries.name.value.?});
            } else if (std.mem.eql(u8, self.args.items[self.index], "%k")) {
                // TODO
                try self.replace(&.{});
            } else if (std.mem.eql(u8, self.args.items[self.index], "%%")) {
                try self.replace(&.{"%"});
            } else if (self.args.items[self.index].len == 2 and self.args.items[self.index][0] == '%') {
                switch (self.args.items[self.index][1]) {
                    'f', 'F', 'u', 'U', 'd', 'D', 'n', 'N', 'v', 'm' => try self.replace(&.{}),
                    else => return error.SyntaxError,
                }
            } else {
                self.index += 1;
            }
        }

        if (self.args.items.len == 0) {
            return error.SyntaxError;
        }
    }
};

fn parseFile(locale: Locale, file: std.fs.File) !?DesktopEntry {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    var entries = try parseEntries(&buf, locale, file);
    defer entries.deinit();

    if (entries.name.value == null) return error.SyntaxError;
    if (entries.type.value == null) return error.SyntaxError;
    if (!std.mem.eql(u8, entries.type.value.?, "Application")) return null;

    var args = try separateArgs(&buf, entries.exec.value orelse return null);
    defer freeArgs(&args);

    var expander = FieldCodeExpander{ .args = &args };
    try expander.expand(entries);

    const name = try allocator.dupeZ(u8, entries.name.value.?);

    const command = DesktopCommand{
        .exec = args.toOwnedSlice(allocator),
        .path = entries.path.value,
    };
    entries.path.value = null;

    const result = DesktopEntry{
        .name = name,
        .command = command,
    };

    return result;
}

fn searchDirectory(
    map: *Map,
    locale: Locale,
    old_dir: std.fs.Dir,
    dir_name: []const u8,
) (std.fs.Dir.Iterator.Error || std.mem.Allocator.Error)!void {
    var dir = old_dir.openDir(dir_name, .{ .iterate = true }) catch |err| {
        std.log.warn("cannot open {s}: {}", .{ dir_name, err });
        return;
    };
    defer dir.close();
    var dir_iterator = dir.iterate();
    while (try dir_iterator.next()) |entry| {
        const stat = util.followStatAt(dir.fd, entry.name) catch |err| {
            std.log.warn("cannot stat {s}: {}", .{ entry.name, err });
            continue;
        };
        if (stat.mode & std.os.S.IFMT == std.os.S.IFDIR) {
            // if it is a directory, recurse into it
            try searchDirectory(map, locale, dir, entry.name);
        } else if (stat.mode & std.os.S.IFMT == std.os.S.IFREG) {
            // try to parse the file
            const file = dir.openFile(entry.name, .{}) catch |err| {
                std.log.warn("cannot open {s}: {}", .{ entry.name, err });
                continue;
            };
            defer file.close();
            if (parseFile(locale, file) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => |e| {
                    // only display warnings if it's explicitly a .desktop file
                    if (std.mem.endsWith(u8, entry.name, ".desktop")) {
                        std.log.warn("failed to parse file {s}: {}", .{ entry.name, e });
                    }
                    continue;
                },
            }) |*e| {
                if (!map.contains(e.name)) {
                    errdefer e.deinit();
                    try map.ensureUnusedCapacity(allocator, 1);
                    map.putAssumeCapacity(e.name, e.command);
                } else {
                    e.deinit();
                }
            }
        }
    }
}

fn searchDirectories() !Map {
    const locale = getLocale();

    var map = Map{};
    errdefer freeMap(&map);

    // check local directory
    if (std.os.getenvZ("XDG_DATA_HOME")) |v| {
        const name = try std.fmt.allocPrint(allocator, "{s}/applications", .{v});
        defer allocator.free(name);
        try searchDirectory(&map, locale, std.fs.cwd(), name);
    } else if (std.os.getenvZ("HOME")) |v| {
        const name = try std.fmt.allocPrint(allocator, "{s}/.local/share/applications", .{v});
        defer allocator.free(name);
        try searchDirectory(&map, locale, std.fs.cwd(), name);
    }
    // check global directories
    const xdg_data_dirs = std.os.getenvZ("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.split(u8, xdg_data_dirs, ":");
    while (it.next()) |dir| {
        const name = try std.fmt.allocPrint(allocator, "{s}/applications", .{dir});
        defer allocator.free(name);
        try searchDirectory(&map, locale, std.fs.cwd(), name);
    }

    return map;
}

pub fn init() !DesktopEntryMode {
    var map = try searchDirectories();
    errdefer freeMap(&map);

    const choices = try allocator.alloc([:0]const u8, map.size);
    errdefer allocator.free(choices);

    var it = map.keyIterator();
    for (choices) |*choice| {
        choice.* = @ptrCast([:0]const u8, it.next().?.*);
    }
    util.sortChoices(choices);

    return DesktopEntryMode{
        .mode = .{
            .choices = choices,
            .custom_allowed = false,
            .executeFn = execute,
        },
        .map = map,
    };
}

pub fn deinit(self: *DesktopEntryMode) void {
    freeMap(&self.map);
    allocator.free(self.mode.choices);
}

fn execute(mode: *Mode, choice: [*:0]const u8) void {
    const self = @fieldParentPtr(DesktopEntryMode, "mode", mode);
    if (self.map.get(std.mem.span(choice))) |command| {
        const argv = allocator.alloc(?[*:0]const u8, command.exec.len + 1) catch {
            std.log.err("failed to allocate arguments", .{});
            return;
        };
        defer allocator.free(argv);
        for (command.exec) |arg, i| {
            argv[i] = arg.ptr;
        }
        argv[command.exec.len] = null;

        const pid = std.os.fork() catch |err| {
            std.log.err("failed to fork process: {}", .{err});
            return;
        };

        if (pid == 0) {
            if (command.path) |path| {
                std.os.chdir(path) catch |err| {
                    std.log.err("failed to chdir into requested path: {}", .{err});
                    std.os.exit(1);
                };
            }
            const err = std.os.execvpeZ(argv[0].?, @ptrCast([*:null]const ?[*:0]const u8, argv.ptr), std.c.environ);
            std.log.err("failed to exec process: {}", .{err});
            std.os.exit(1);
        }
    }
}

fn testAllocs(a: std.mem.Allocator) !void {
    @import("../main.zig").test_allocator.backing = a;
    var desktop_entry_mode = try DesktopEntryMode.init();
    defer desktop_entry_mode.deinit();
}

test "failing allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testAllocs, .{});
}
