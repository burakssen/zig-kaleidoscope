const std = @import("std");
pub const Token = @import("token.zig").Token;

pub const LexError = error{
    InvalidNumber,
};

const Lexer = @This();

input: [:0]const u8,
pos: usize = 0,

pub fn init(input: [:0]const u8) Lexer {
    return .{
        .input = input,
    };
}

pub fn next(self: *Lexer) LexError!Token {
    while (true) {
        self.skipWhitespace();

        const c = self.peek() orelse return .eof;

        if (c == '#') {
            self.skipComment();
            continue;
        }

        if (std.ascii.isAlphabetic(c)) {
            return self.identifier();
        }

        if (std.ascii.isDigit(c) or c == '.') {
            return self.number();
        }

        _ = self.advance();
        return .{ .character = c };
    }
}

fn identifier(self: *Lexer) Token {
    const start = self.pos;

    while (self.peek()) |c| {
        if (!std.ascii.isAlphanumeric(c)) break;
        _ = self.advance();
    }

    const text = self.input[start..self.pos];
    if (std.mem.eql(u8, text, "def")) return .def;
    if (std.mem.eql(u8, text, "extern")) return .@"extern";
    if (std.mem.eql(u8, text, "if")) return .@"if";
    if (std.mem.eql(u8, text, "then")) return .then;
    if (std.mem.eql(u8, text, "else")) return .@"else";
    if (std.mem.eql(u8, text, "for")) return .@"for";
    if (std.mem.eql(u8, text, "in")) return .in;
    if (std.mem.eql(u8, text, "binary")) return .binary;
    if (std.mem.eql(u8, text, "unary")) return .unary;
    if (std.mem.eql(u8, text, "var")) return .@"var";

    return .{ .identifier = text };
}

fn number(self: *Lexer) LexError!Token {
    const start = self.pos;
    while (self.peek()) |c| {
        if (!std.ascii.isDigit(c) and c != '.') break;
        _ = self.advance();
    }

    const text = self.input[start..self.pos];
    const value = try parseSimpleFloat(text);
    return .{ .number = value };
}

fn skipWhitespace(self: *Lexer) void {
    while (self.peek()) |c| {
        if (!std.ascii.isWhitespace(c)) break;
        _ = self.advance();
    }
}

fn skipComment(self: *Lexer) void {
    while (self.peek()) |c| {
        if (c == '\n' or c == '\r') break;
        _ = self.advance();
    }
}

fn peek(self: *const Lexer) ?u8 {
    if (self.pos >= self.input.len) return null;
    return self.input[self.pos];
}

fn advance(self: *Lexer) ?u8 {
    if (self.pos >= self.input.len) return null;

    const c = self.input[self.pos];
    self.pos += 1;
    return c;
}

fn parseSimpleFloat(text: []const u8) LexError!f64 {
    var value: f64 = 0;
    var scale: f64 = 1;
    var seen_dot = false;
    var seen_digit = false;

    for (text) |c| {
        if (c == '.') {
            if (seen_dot) return LexError.InvalidNumber;
            seen_dot = true;
            continue;
        }

        if (!std.ascii.isDigit(c)) return LexError.InvalidNumber;
        seen_digit = true;

        const digit: f64 = @floatFromInt(c - '0');
        if (seen_dot) {
            scale *= 10;
            value += digit / scale;
        } else {
            value = value * 10 + digit;
        }
    }

    if (!seen_digit) return LexError.InvalidNumber;
    return value;
}
