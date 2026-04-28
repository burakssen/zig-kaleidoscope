const std = @import("std");

pub const Token = union(enum) {
    eof,

    // Commands.
    def,
    @"extern",

    // Primary values.
    identifier: []const u8,
    number: f64,

    // Control flow.
    @"if",
    then,
    @"else",
    @"for",
    in,

    binary,
    unary,

    // Any otherwise unknown character, such as '+', '-', '(', or ')'.
    character: u8,

    pub fn format(
        self: Token,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .eof => try writer.print("eof", .{}),
            .def => try writer.print("def", .{}),
            .@"extern" => try writer.print("extern", .{}),
            .identifier => |val| try writer.print("identifier: {s}", .{val}),
            .number => |n| try writer.print("number: {d}", .{n}),
            .character => |c| try writer.print("character: {c}", .{c}),
        }
        try writer.print("\n", .{});
    }
};
