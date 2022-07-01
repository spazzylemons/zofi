pub const c = @cImport({
    @cInclude("gtk-3.0/gtk/gtk.h");
    @cInclude("gtk-layer-shell.h");
});

pub const FALSE: c.gboolean = 0;
pub const TRUE: c.gboolean = 1;

fn UnwrapOptional(comptime T: type) type {
    if (@typeInfo(T) == .Optional) {
        return @typeInfo(T).Optional.child;
    }
    return T;
}

fn ptrAlignment(comptime T: type) comptime_int {
    if (@typeInfo(T) == .Fn) {
        return 1;
    }
    const Child = @typeInfo(T).Pointer.child;
    if (@typeInfo(Child) == .Opaque) {
        return 1;
    }
    return @alignOf(Child);
}

/// helper function to cast pointers to avoid typing alignCast and alignOf too much
pub inline fn ptrCast(comptime T: type, value: anytype) T {
    return @ptrCast(T, @alignCast(ptrAlignment(UnwrapOptional(T)), value));
}

/// Perofrm a checked cast to another GType.
pub inline fn cast(comptime T: type, value: anytype, ty: c.GType) *T {
    return ptrCast(*T, c.g_type_check_instance_cast(ptrCast(*c.GTypeInstance, value), ty));
}

pub inline fn signalConnect(instance: anytype, detailed_signal: [*:0]const u8, c_handler: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(instance, detailed_signal, ptrCast(c.GCallback, c_handler), data, null, 0);
}

pub inline fn signalConnectSwapped(instance: anytype, detailed_signal: [*:0]const u8, c_handler: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(instance, detailed_signal, ptrCast(c.GCallback, c_handler), data, null, c.G_CONNECT_SWAPPED);
}
