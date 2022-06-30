const g = @import("g.zig");
const std = @import("std");

fn onActivate(app: *g.c.GtkApplication, data: ?*anyopaque) callconv(.C) void {
    _ = data;

    const window_widget = g.c.gtk_application_window_new(app);
    const window = g.cast(g.c.GtkWindow, window_widget, g.c.gtk_window_get_type());
    g.c.gtk_layer_init_for_window(window);
    g.c.gtk_layer_set_layer(window, g.c.GTK_LAYER_SHELL_LAYER_TOP);

    const label = g.c.gtk_label_new("");
    g.c.gtk_label_set_markup(g.cast(g.c.GtkLabel, label, g.c.gtk_label_get_type()),
        \\<span font_desc="20.0">
        \\  GTK Layer Shell Example!
        \\</span>
    );
    const window_container = g.cast(g.c.GtkContainer, window, g.c.gtk_container_get_type());
    g.c.gtk_container_add(window_container, label);
    g.c.gtk_container_set_border_width(window_container, 12);
    g.c.gtk_widget_show_all(window_widget);
}

pub fn main() u8 {
    const app = g.c.gtk_application_new("spazzylemons.zofi", g.c.G_APPLICATION_FLAGS_NONE);
    defer g.c.g_object_unref(app);
    g.signalConnect(app, "activate", onActivate, null);
    const g_app = g.cast(g.c.GApplication, app, g.c.g_application_get_type());
    return @truncate(u8, @bitCast(u32, g.c.g_application_run(g_app, 0, null)));
}
