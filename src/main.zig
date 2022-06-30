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

const Client = struct {
    exes: []const []const u8,
    entry_list: *g.c.GtkWidget = undefined,
    entry: *g.c.GtkEntry = undefined,

    fn rebuildList(self: *Client) void {
        const input = std.mem.span(g.c.gtk_entry_get_text(self.entry));

        const list_box_widget = g.c.gtk_list_box_new();
        const list_box = g.cast(g.c.GtkListBox, list_box_widget, g.c.gtk_list_box_get_type());
        const list_box_container = g.cast(g.c.GtkContainer, list_box, g.c.gtk_container_get_type());

        var buf: [std.os.PATH_MAX + 1]u8 = undefined;

        for (self.exes) |exe| {
            if (std.mem.indexOf(u8, exe, input) == null) continue;
            std.mem.copy(u8, &buf, exe);
            buf[exe.len] = 0;
            const label = g.c.gtk_label_new(&buf);
            g.c.gtk_container_add(list_box_container, label);
        }

        const scrolled_window_widget = g.c.gtk_scrolled_window_new(null, null);
        const scrolled_window = g.cast(g.c.GtkScrolledWindow, scrolled_window_widget, g.c.gtk_scrolled_window_get_type());

        g.c.gtk_container_add(g.cast(g.c.GtkContainer, scrolled_window, g.c.gtk_container_get_type()), list_box_widget);
        g.c.gtk_scrolled_window_set_min_content_height(scrolled_window, 320);
        g.c.gtk_scrolled_window_set_min_content_width(scrolled_window, 640);

        g.c.gtk_list_box_set_selection_mode(list_box, g.c.GTK_SELECTION_BROWSE);

        if (@ptrCast(?*g.c.GList, g.c.gtk_container_get_children(list_box_container))) |child_node| {
            g.c.gtk_list_box_select_row(list_box, g.cast(g.c.GtkListBoxRow, child_node.data, g.c.gtk_list_box_row_get_type()));
        }

        const box_container = g.cast(g.c.GtkContainer, g.c.gtk_widget_get_parent(self.entry_list), g.c.gtk_container_get_type());
        g.c.gtk_container_remove(box_container, self.entry_list);
        g.c.gtk_container_add(box_container, scrolled_window_widget);
        self.entry_list = scrolled_window_widget;
        g.c.gtk_widget_show_all(scrolled_window_widget);
    }
};

fn onChanged(editable: ?*g.c.GtkEditable, self: *Client) callconv(.C) void {
    _ = editable;
    self.rebuildList();
}

fn onActivate(app: *g.c.GtkApplication, self: *Client) callconv(.C) void {
    const window_widget = g.c.gtk_application_window_new(app);
    const window = g.cast(g.c.GtkWindow, window_widget, g.c.gtk_window_get_type());
    g.c.gtk_layer_init_for_window(window);
    g.c.gtk_layer_set_layer(window, g.c.GTK_LAYER_SHELL_LAYER_TOP);
    g.c.gtk_layer_set_keyboard_mode(window, g.c.GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);

    const box_widget = g.c.gtk_box_new(g.c.GTK_ORIENTATION_VERTICAL, 0);
    const box_container = g.cast(g.c.GtkContainer, box_widget, g.c.gtk_container_get_type());

    const command_entry_widget = g.c.gtk_entry_new();
    const command_entry = g.cast(g.c.GtkEntry, command_entry_widget, g.c.gtk_entry_get_type());
    g.c.gtk_entry_set_icon_from_icon_name(command_entry, g.c.GTK_ENTRY_ICON_PRIMARY, "edit-find");
    g.c.gtk_container_add(box_container, command_entry_widget);
    g.signalConnect(command_entry, "changed", onChanged, self);

    self.entry = command_entry;
    self.entry_list = g.c.gtk_label_new("");
    g.c.gtk_container_add(box_container, self.entry_list);
    self.rebuildList();

    const window_container = g.cast(g.c.GtkContainer, window, g.c.gtk_container_get_type());
    g.c.gtk_container_add(window_container, box_widget);
    g.c.gtk_container_set_border_width(window_container, 12);
    // TODO - large ListBox is slow, consider loading elements on-demand somehow
    g.c.gtk_widget_show_all(window_widget);
}

fn stringLessThan(context: void, p: []const u8, q: []const u8) bool {
    _ = context;
    return std.mem.order(u8, p, q) == .lt;
}

pub fn main() u8 {
    defer _ = gpa.deinit();

    var exe_map = searchPath() catch |err| {
        std.log.err("failed to search path: {}", .{err});
        return 1;
    };
    defer exe_map.deinit();

    var sorted = std.ArrayListUnmanaged([]const u8){};
    defer sorted.deinit(allocator);

    var it = exe_map.data.keyIterator();
    while (it.next()) |key| {
        sorted.append(allocator, key.*) catch {
            std.log.err("out of memory", .{});
            return 1;
        };
    }
    std.sort.sort([]const u8, sorted.items, {}, stringLessThan);
    var client = Client{ .exes = sorted.items };

    const app = g.c.gtk_application_new("spazzylemons.zofi", g.c.G_APPLICATION_FLAGS_NONE);
    defer g.c.g_object_unref(app);
    g.signalConnect(app, "activate", onActivate, &client);
    const g_app = g.cast(g.c.GApplication, app, g.c.g_application_get_type());
    return @truncate(u8, @bitCast(u32, g.c.g_application_run(g_app, 0, null)));
}
