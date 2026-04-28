const std = @import("std");

pub const HostSymbol = struct {
    name: []const u8,
    address: usize,
};

pub export fn putchard(x: f64) f64 {
    const ch: u8 = @intFromFloat(x);
    std.debug.print("{c}", .{ch});
    return 0.0;
}

pub export fn printd(x: f64) f64 {
    std.debug.print("{d}\n", .{x});
    return 0.0;
}

pub fn hostSymbols() [2]HostSymbol {
    return .{
        .{ .name = "putchard", .address = @intFromPtr(&putchard) },
        .{ .name = "printd", .address = @intFromPtr(&printd) },
    };
}
