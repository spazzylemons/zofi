const g = @import("g.zig");
const std = @import("std");

const Launcher = @This();

/// A sorted list of executable names.
exes: []const [:0]const u8,
/// The widget containing the current command.
command: *g.c.GtkEntry = undefined,
/// The current view containing the list of executables to display.
view: *g.c.GtkTreeView = undefined,
/// The current selection of the tree view.
selection: *g.c.GtkTreeSelection = undefined,

// GdkEventKey has a bitfield, so it can't be parsed by Zig.
// we'll define it ourselves, but ignore the bitfield
const GdkEventKey = extern struct {
    type: g.c.GdkEventType,
    window: *g.c.GdkWindow,
    send_event: g.c.gint8,
    time: g.c.guint32,
    state: g.c.GdkModifierType,
    keyval: g.c.guint,
    length: g.c.gint,
    string: [*:0]g.c.gchar,
    hardware_keycode: g.c.guint16,
    group: g.c.guint8,
};

fn rebuildList(self: *Launcher) callconv(.C) void {
    const input = std.mem.span(g.c.gtk_entry_get_text(self.command));

    var iter: g.c.GtkTreeIter = undefined;
    const store = g.c.gtk_list_store_new(1, g.c.G_TYPE_STRING);
    defer g.c.g_object_unref(store);

    var contains_entries = false;

    // take names that start with the input first
    for (self.exes) |exe| {
        if (!std.mem.startsWith(u8, exe, input)) continue;
        g.c.gtk_list_store_append(store, &iter);
        g.c.gtk_list_store_set(store, &iter, @as(c_int, 0), exe.ptr, @as(c_int, -1));
        contains_entries = true;
    }

    // TODO DRY
    for (self.exes) |exe| {
        if (exe.ptr[0] == input.ptr[0]) continue;
        if ((std.mem.indexOf(u8, exe, input) orelse continue) == 0) continue;
        g.c.gtk_list_store_append(store, &iter);
        g.c.gtk_list_store_set(store, &iter, @as(c_int, 0), exe.ptr, @as(c_int, -1));
        contains_entries = true;
    }

    g.c.gtk_tree_view_set_model(self.view, g.cast(g.c.GtkTreeModel, store, g.c.gtk_tree_model_get_type()));

    self.selection = g.c.gtk_tree_view_get_selection(self.view);
    g.c.gtk_tree_selection_set_mode(self.selection, g.c.GTK_SELECTION_BROWSE);

    if (contains_entries) {
        const path = g.c.gtk_tree_path_new_first();
        defer g.c.gtk_tree_path_free(path);
        g.c.gtk_tree_selection_select_path(self.selection, path);
        // show find icon because pressing enter will run the selected application
        g.c.gtk_entry_set_icon_from_icon_name(self.command, g.c.GTK_ENTRY_ICON_PRIMARY, "edit-find");
    } else {
        // show run icon because pressing enter will run what is in the entry widget
        g.c.gtk_entry_set_icon_from_icon_name(self.command, g.c.GTK_ENTRY_ICON_PRIMARY, "system-run");
    }
}

fn useIter(self: *Launcher, model: *g.c.GtkTreeModel, iter: *g.c.GtkTreeIter) void {
    g.c.gtk_tree_selection_select_iter(self.selection, iter);
    const path = g.c.gtk_tree_model_get_path(model, iter);
    defer g.c.gtk_tree_path_free(path);
    g.c.gtk_tree_view_scroll_to_cell(self.view, path, null, g.FALSE, 0, 0);
}

fn runCommand(command: [*:0]const u8) void {
    const pid = std.os.fork() catch |err| {
        std.log.err("failed to fork process: {}", .{err});
        return;
    };

    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", command, null };
        const err = std.os.execveZ("/bin/sh", &argv, std.c.environ);
        std.log.err("failed to exec process: {}", .{err});
        std.os.exit(1);
    }
}

fn moveSelection(self: *Launcher, func: fn (?*g.c.GtkTreeModel, ?*g.c.GtkTreeIter) callconv(.C) g.c.gboolean) void {
    var iter: g.c.GtkTreeIter = undefined;
    var model: ?*g.c.GtkTreeModel = null;
    if (g.c.gtk_tree_selection_get_selected(self.selection, &model, &iter) != g.FALSE) {
        if (func(model, &iter) != g.FALSE) {
            self.useIter(model.?, &iter);
        }
    }
}

fn onKeyPress(window: *g.c.GtkWindow, event: *const GdkEventKey, self: *Launcher) callconv(.C) g.c.gboolean {
    switch (event.keyval) {
        g.c.GDK_KEY_Up => {
            self.moveSelection(g.c.gtk_tree_model_iter_previous);
            return g.TRUE;
        },

        g.c.GDK_KEY_Down => {
            self.moveSelection(g.c.gtk_tree_model_iter_next);
            return g.TRUE;
        },

        g.c.GDK_KEY_Escape => {
            g.c.gtk_window_close(window);
            return g.TRUE;
        },

        g.c.GDK_KEY_Return => {
            var iter: g.c.GtkTreeIter = undefined;
            var model: ?*g.c.GtkTreeModel = null;
            if (g.c.gtk_tree_selection_get_selected(self.selection, &model, &iter) != g.FALSE) {
                var value = std.mem.zeroes(g.c.GValue);
                g.c.gtk_tree_model_get_value(model, &iter, 0, &value);
                defer g.c.g_value_unset(&value);
                runCommand(g.c.g_value_get_string(&value));
            } else {
                runCommand(g.c.gtk_entry_get_text(self.command));
            }
            g.c.gtk_window_close(window);

            return g.TRUE;
        },

        else => return g.FALSE,
    }
}

fn onActivate(app: *g.c.GtkApplication, self: *Launcher) callconv(.C) void {
    const window_widget = g.c.gtk_application_window_new(app);
    const window = g.cast(g.c.GtkWindow, window_widget, g.c.gtk_window_get_type());
    g.c.gtk_layer_init_for_window(window);
    g.c.gtk_layer_set_layer(window, g.c.GTK_LAYER_SHELL_LAYER_TOP);
    g.c.gtk_layer_set_keyboard_mode(window, g.c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
    g.signalConnect(window, "key-press-event", onKeyPress, self);

    const box_widget = g.c.gtk_box_new(g.c.GTK_ORIENTATION_VERTICAL, 0);
    const list_container = g.cast(g.c.GtkContainer, box_widget, g.c.gtk_container_get_type());

    const entry_widget = g.c.gtk_entry_new();
    self.command = g.cast(g.c.GtkEntry, entry_widget, g.c.gtk_entry_get_type());
    g.c.gtk_container_add(list_container, entry_widget);
    g.signalConnectSwapped(self.command, "changed", rebuildList, self);

    const view_widget = g.c.gtk_tree_view_new();
    self.view = g.cast(g.c.GtkTreeView, view_widget, g.c.gtk_tree_view_get_type());

    const renderer = g.c.gtk_cell_renderer_text_new();
    _ = g.c.gtk_tree_view_insert_column_with_attributes(
        self.view,
        @as(c_int, -1),
        @as(?[*:0]const u8, null),
        renderer,
        // first attribute at column 0
        @as(?[*:0]const u8, "text"),
        @as(c_int, 0),
        // no more attributes
        @as(?[*:0]const u8, null),
    );
    g.c.gtk_tree_view_set_headers_visible(self.view, g.FALSE);

    const scrolled_window_widget = g.c.gtk_scrolled_window_new(null, null);
    const scrolled_window = g.cast(g.c.GtkScrolledWindow, scrolled_window_widget, g.c.gtk_scrolled_window_get_type());

    g.c.gtk_container_add(g.cast(g.c.GtkContainer, scrolled_window, g.c.gtk_container_get_type()), view_widget);
    // TODO configurable
    g.c.gtk_scrolled_window_set_min_content_height(scrolled_window, 320);
    g.c.gtk_scrolled_window_set_min_content_width(scrolled_window, 640);

    g.c.gtk_container_add(list_container, scrolled_window_widget);

    self.rebuildList();

    const window_container = g.cast(g.c.GtkContainer, window, g.c.gtk_container_get_type());
    g.c.gtk_container_add(window_container, box_widget);
    g.c.gtk_widget_show_all(window_widget);
}

pub fn run(exes: []const [:0]const u8) u8 {
    // create instance
    var self = Launcher{ .exes = exes };
    // create app
    const app = g.c.gtk_application_new("spazzylemons.zofi", g.c.G_APPLICATION_FLAGS_NONE);
    defer g.c.g_object_unref(app);
    // hook into activation signal for initialization
    g.signalConnect(app, "activate", onActivate, &self);
    // run application
    const g_app = g.cast(g.c.GApplication, app, g.c.g_application_get_type());
    return @truncate(u8, @bitCast(u32, g.c.g_application_run(g_app, 0, null)));
}