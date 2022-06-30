const g = @import("g.zig");
const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const ExeMap = struct {
    data: std.StringHashMapUnmanaged(void) = .{},

    fn deinit(self: *ExeMap) void {
        var it = self.data.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        self.data.deinit(allocator);
    }
};

fn searchPath() !ExeMap {
    // get the path variable, otherwise we don't know what we can run
    const path = std.os.getenvZ("PATH") orelse return error.NoPath;
    // collect executable names here
    var result = ExeMap{};
    errdefer result.deinit();
    // iterate over each path in PATH
    var path_iterator = std.mem.split(u8, path, ":");
    while (path_iterator.next()) |dir_name| {
        // open directory in iteration mode
        var dir = std.fs.cwd().openDir(dir_name, .{ .iterate = true }) catch |err| {
            // report and more on
            std.log.warn("cannot open path directory {s}: {}", .{ dir_name, err });
            continue;
        };
        defer dir.close();
        // chcek each file in the directory
        var dir_iterator = dir.iterate();
        while (try dir_iterator.next()) |entry| {
            // follow symlinks
            var full_path_buf: [std.fs.MAX_PATH_BYTES + 1]u8 = undefined;
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
            try result.data.ensureUnusedCapacity(allocator, 1);
            const copy = try allocator.dupe(u8, entry.name);
            result.data.putAssumeCapacity(copy, {});
        }
    }
    // all executables have been collected
    return result;
}

fn extractLabel(row: ?*g.c.GtkListBoxRow) [*:0]const u8 {
    const children = g.c.gtk_container_get_children(g.cast(g.c.GtkContainer, row, g.c.gtk_container_get_type()));
    const label = g.cast(g.c.GtkLabel, children.*.data, g.c.gtk_label_get_type());
    return g.c.gtk_label_get_text(label);
}

fn sortRows(row1: ?*g.c.GtkListBoxRow, row2: ?*g.c.GtkListBoxRow, user_data: ?*anyopaque) callconv(.C) g.c.gint {
    // NOTE: this does not handle identical strings as they should not be encountered
    _ = user_data;
    var p = extractLabel(row1);
    var q = extractLabel(row2);
    while (true) {
        const x = @as(g.c.gint, p[0]);
        const y = @as(g.c.gint, q[0]);
        if (x != y) {
            return x - y;
        }
        p += 1;
        q += 1;
    }
}

fn onActivate(app: *g.c.GtkApplication, exe_map: *ExeMap) callconv(.C) void {
    const window_widget = g.c.gtk_application_window_new(app);
    const window = g.cast(g.c.GtkWindow, window_widget, g.c.gtk_window_get_type());
    g.c.gtk_layer_init_for_window(window);
    g.c.gtk_layer_set_layer(window, g.c.GTK_LAYER_SHELL_LAYER_TOP);
    g.c.gtk_layer_set_keyboard_mode(window, g.c.GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);

    const scrolled_window_widget = g.c.gtk_scrolled_window_new(null, null);
    const scrolled_window = g.cast(g.c.GtkScrolledWindow, scrolled_window_widget, g.c.gtk_scrolled_window_get_type());

    const list_box_widget = g.c.gtk_list_box_new();
    const list_box = g.cast(g.c.GtkListBox, list_box_widget, g.c.gtk_list_box_get_type());
    const list_box_container = g.cast(g.c.GtkContainer, list_box, g.c.gtk_container_get_type());
    g.c.gtk_list_box_set_sort_func(list_box, sortRows, null, null);

    var it = exe_map.data.keyIterator();
    while (it.next()) |key| {
        const string = allocator.dupeZ(u8, key.*) catch {
            std.log.warn("failed to allocate entry {s}", .{key.*});
            continue;
        };
        defer allocator.free(string);
        const label = g.c.gtk_label_new(string.ptr);
        g.c.gtk_container_add(list_box_container, label);
    }

    g.c.gtk_container_add(g.cast(g.c.GtkContainer, scrolled_window, g.c.gtk_container_get_type()), list_box_widget);
    g.c.gtk_scrolled_window_set_min_content_height(scrolled_window, 320);
    g.c.gtk_scrolled_window_set_min_content_width(scrolled_window, 640);

    const window_container = g.cast(g.c.GtkContainer, window, g.c.gtk_container_get_type());
    g.c.gtk_container_add(window_container, scrolled_window_widget);
    g.c.gtk_container_set_border_width(window_container, 12);
    // TODO - large ListBox is slow, consider loading elements on-demand somehow
    g.c.gtk_widget_show_all(window_widget);
}

pub fn main() u8 {
    defer _ = gpa.deinit();

    var exe_map = searchPath() catch |err| {
        std.log.err("failed to search path: {}", .{err});
        return 1;
    };
    defer exe_map.deinit();

    const app = g.c.gtk_application_new("spazzylemons.zofi", g.c.G_APPLICATION_FLAGS_NONE);
    defer g.c.g_object_unref(app);
    g.signalConnect(app, "activate", onActivate, &exe_map);
    const g_app = g.cast(g.c.GApplication, app, g.c.g_application_get_type());
    return @truncate(u8, @bitCast(u32, g.c.g_application_run(g_app, 0, null)));
}
