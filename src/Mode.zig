//! A mode of operation.

const Mode = @This();

/// The choices the user can select from. Must be lexicographically sorted.
choices: []const [:0]const u8,
/// If true, pressing enter without a selected choice is valid.
custom_allowed: bool,
/// The operation to run with the selected choice.
executeFn: fn (mode: *Mode, choice: [*:0]const u8) void,

/// Run the mode's execute function.
pub inline fn execute(self: *Mode, choice: [*:0]const u8) void {
    self.executeFn(self, choice);
}
