const g = @import("g.zig");
const Mode = @import("Mode.zig");
const std = @import("std");

const Launcher = @This();

/// The width of the window.
width: u15,
/// The height of the window.
height: u15,
/// The mode to run in.
mode: *Mode,
/// The widget containing the current command.
command: *g.c.GtkEntry = undefined,
/// The current view containing the list of choices to display.
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

const ChoiceFilter = struct {
    input: []const u8,
    choices: []const [:0]const u8,
    store: *g.c.GtkListStore,

    fn filterOnce(self: *ChoiceFilter, starting: bool) void {
        for (self.choices) |choice| {
            if (starting) {
                if (!std.ascii.startsWithIgnoreCase(choice, self.input)) continue;
            } else {
                if (std.ascii.indexOfIgnoreCase(choice, self.input)) |index| {
                    if (index == 0) continue;
                } else continue;
            }
            var iter: g.c.GtkTreeIter = undefined;
            g.c.gtk_list_store_append(self.store, &iter);
            g.c.gtk_list_store_set(
                self.store,
                &iter,
                // put name in column 0
                @as(c_int, 0),
                choice.ptr,
                // end of list
                @as(c_int, -1),
            );
        }
    }

    fn filter(self: *ChoiceFilter) void {
        self.filterOnce(true);
        self.filterOnce(false);
    }
};

fn rebuildList(self: *Launcher) callconv(.C) void {
    const input = std.mem.span(g.c.gtk_entry_get_text(self.command));

    const store = g.c.gtk_list_store_new(1, g.c.G_TYPE_STRING);
    defer g.c.g_object_unref(store);

    var filter = ChoiceFilter{ .input = input, .choices = self.mode.choices, .store = store };
    filter.filter();

    const model = g.cast(g.c.GtkTreeModel, store, g.c.gtk_tree_model_get_type());
    g.c.gtk_tree_view_set_model(self.view, model);

    self.selection = g.c.gtk_tree_view_get_selection(self.view);
    g.c.gtk_tree_selection_set_mode(self.selection, g.c.GTK_SELECTION_BROWSE);

    var iter: g.c.GtkTreeIter = undefined;
    // show find icon to indicate search result will be used
    g.c.gtk_entry_set_icon_from_icon_name(self.command, g.c.GTK_ENTRY_ICON_PRIMARY, "edit-find");
    // check if any entries exist in the list
    if (g.c.gtk_tree_model_get_iter_first(model, &iter) != g.FALSE) {
        // if so, select the first entry
        g.c.gtk_tree_selection_select_iter(self.selection, &iter);
    } else if (self.mode.custom_allowed) {
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
                self.mode.execute(g.c.g_value_get_string(&value));
                g.c.gtk_window_close(window);
                return g.TRUE;
            }

            if (self.mode.custom_allowed) {
                self.mode.execute(g.c.gtk_entry_get_text(self.command));
                g.c.gtk_window_close(window);
                return g.TRUE;
            }

            return g.FALSE;
        },

        g.c.GDK_KEY_Tab => {
            var iter: g.c.GtkTreeIter = undefined;
            var model: ?*g.c.GtkTreeModel = null;
            if (g.c.gtk_tree_selection_get_selected(self.selection, &model, &iter) != g.FALSE) {
                var value = std.mem.zeroes(g.c.GValue);
                g.c.gtk_tree_model_get_value(model, &iter, 0, &value);
                defer g.c.g_value_unset(&value);
                g.c.gtk_entry_set_text(self.command, g.c.g_value_get_string(&value));
                g.c.gtk_entry_grab_focus_without_selecting(self.command);
                g.c.gtk_editable_set_position(g.cast(g.c.GtkEditable, self.command, g.c.gtk_editable_get_type()), -1);
            }

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
    g.c.gtk_window_set_default_size(window, self.width, self.height);
    g.c.gtk_window_set_resizable(window, g.FALSE);

    const box_widget = g.c.gtk_box_new(g.c.GTK_ORIENTATION_VERTICAL, 0);
    const box = g.cast(g.c.GtkBox, box_widget, g.c.gtk_box_get_type());
    const box_container = g.cast(g.c.GtkContainer, box, g.c.gtk_container_get_type());

    const entry_widget = g.c.gtk_entry_new();
    self.command = g.cast(g.c.GtkEntry, entry_widget, g.c.gtk_entry_get_type());
    g.c.gtk_container_add(box_container, entry_widget);
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
    g.c.gtk_box_pack_end(box, scrolled_window_widget, g.TRUE, g.TRUE, 0);

    self.rebuildList();

    const window_container = g.cast(g.c.GtkContainer, window, g.c.gtk_container_get_type());
    g.c.gtk_container_add(window_container, box_widget);
    g.c.gtk_widget_show_all(window_widget);
}

pub fn run(mode: *Mode, width: u15, height: u15) u8 {
    // create instance
    var self = Launcher{ .mode = mode, .width = width, .height = height };
    // create app
    const app = g.c.gtk_application_new("spazzylemons.zofi", g.c.G_APPLICATION_FLAGS_NONE);
    defer g.c.g_object_unref(app);
    // hook into activation signal for initialization
    g.signalConnect(app, "activate", onActivate, &self);
    // run application
    const g_app = g.cast(g.c.GApplication, app, g.c.g_application_get_type());
    return @truncate(u8, @bitCast(u32, g.c.g_application_run(g_app, 0, null)));
}
