const std = @import("std");
pub const Expr = @import("expr.zig").Expr;
const operators = @import("operators.zig");
const Lexer = @import("lexer");
const Token = Lexer.Token;

pub const ParserError = error{
    ExpectedExpression,
    ExpectedIdentifier,
    ExpectedFunctionName,
    ExpectedOpenParenInPrototype,
    ExpectedCloseParen,
    ExpectedCloseParenInPrototype,
    ExpectedCommaOrCloseParen,

    ExpectedThen,
    ExpectedElse,
    ExpectedIdentifierAfterFor,
    ExpectedEqualsAfterFor,
    ExpectedCommaAfterForStartValue,
    ExpectedInAfterFor,

    ExpectedUnaryOperator,
    ExpectedBinaryOperator,
    InvalidPrecedence,
    InvalidNumberOfOperatorOperands,

    ExpectedIdentifierAfterVar,
    ExpectedIdentifierListAfterVar,
    ExpectedInAfterVar,
} || std.mem.Allocator.Error || Lexer.LexError;

const Parser = @This();

allocator: std.mem.Allocator,
lexer: Lexer,
current: Token,
anonymous_function_count: usize = 0,
binop_precedence: [256]i32 = defaultBinopPrecedence(),

pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) !Parser {
    var parser = Parser{
        .allocator = allocator,
        .lexer = Lexer.init(source),
        .current = .eof,
    };
    try parser.advance();
    return parser;
}

pub fn advance(self: *Parser) !void {
    self.current = try self.lexer.next();
}

fn isChar(self: *const Parser, expected: u8) bool {
    return switch (self.current) {
        .character => |actual| actual == expected,
        else => false,
    };
}

fn getTokPrecedence(self: *const Parser) i32 {
    const op = switch (self.current) {
        .character => |c| c,
        else => return -1,
    };

    return self.binop_precedence[op];
}

fn defaultBinopPrecedence() [256]i32 {
    return operators.defaults();
}

pub fn registerPrototype(self: *Parser, proto: *const Expr.Prototype) !void {
    return operators.registerPrototype(&self.binop_precedence, proto);
}

fn makeExpr(self: *Parser, expr: Expr) !*Expr {
    const node = try self.allocator.create(Expr);
    node.* = expr;
    return node;
}

fn makePrototype(self: *Parser, proto: Expr.Prototype) !*Expr.Prototype {
    const node = try self.allocator.create(Expr.Prototype);
    node.* = proto;
    return node;
}

fn makeFunction(self: *Parser, function: Expr.Function) !*Expr.Function {
    const node = try self.allocator.create(Expr.Function);
    node.* = function;
    return node;
}

/// varexpr ::= 'var' identifier ('=' expression)?
///                     (',' identifier ('=' expression)?)*
fn parseVarExpr(self: *Parser) !*Expr {
    try self.advance(); // eat 'var'

    var bindings: std.ArrayList(Expr.VarBinding) = .empty;
    defer bindings.deinit(self.allocator);

    if (self.current != .identifier) {
        return ParserError.ExpectedIdentifierAfterVar;
    }

    while (true) {
        const name = switch (self.current) {
            .identifier => |identifier| identifier,
            else => return ParserError.ExpectedIdentifierAfterVar,
        };

        try self.advance(); // eat identifier

        var initialize: ?*Expr = null;
        if (self.isChar('=')) {
            try self.advance(); // eat '='
            initialize = try self.parseExpression();
        }

        try bindings.append(self.allocator, .{
            .name = name,
            .init = initialize,
        });

        if (!self.isChar(',')) break;
        try self.advance(); // eat ','

        if (self.current != .identifier) {
            return ParserError.ExpectedIdentifierListAfterVar;
        }
    }

    if (self.current != .in) {
        return ParserError.ExpectedInAfterVar;
    }

    try self.advance(); // eat 'in'

    const body = try self.parseExpression();
    const owned_bindings = try bindings.toOwnedSlice(self.allocator);

    return self.makeExpr(.{
        .var_expr = .{
            .bindings = owned_bindings,
            .body = body,
        },
    });
}

/// numberexpr ::= number
fn parseNumberExpr(self: *Parser) !*Expr {
    const value = switch (self.current) {
        .number => |n| n,
        else => return ParserError.ExpectedExpression,
    };

    try self.advance();
    return self.makeExpr(.{ .number = value });
}

/// parenexpr ::= '(' expression ')'
fn parseParenExpr(self: *Parser) !*Expr {
    try self.advance(); // eat '('

    const expr = try self.parseExpression();

    if (!self.isChar(')')) {
        return ParserError.ExpectedCloseParen;
    }

    try self.advance(); // eat ')'
    return expr;
}

/// identifierexpr
///   ::= identifier
///   ::= identifier '(' expression* ')'
fn parseIdentifierExpr(self: *Parser) !*Expr {
    const id_name = switch (self.current) {
        .identifier => |name| name,
        else => return error.ExpectedIdentifier,
    };

    try self.advance(); // eat identifier

    // Simple variable reference.
    if (!self.isChar('(')) {
        return self.makeExpr(.{ .variable = id_name });
    }

    // Function call.
    try self.advance(); // eat '('

    var args: std.ArrayList(*Expr) = .empty;
    defer args.deinit(self.allocator);

    if (!self.isChar(')')) {
        while (true) {
            const arg = try self.parseExpression();
            try args.append(self.allocator, arg);

            if (self.isChar(')')) {
                break;
            }

            if (!self.isChar(',')) {
                return error.ExpectedCommaOrCloseParen;
            }

            try self.advance(); // eat ','
        }
    }

    try self.advance(); // eat ')'

    const owned_args = try args.toOwnedSlice(self.allocator);
    return self.makeExpr(.{
        .call = .{
            .callee = id_name,
            .args = owned_args,
        },
    });
}

/// ifexpr ::= 'if' expression 'then' expression 'else' expression
/// ifexpr ::= 'if' expression 'then' expression 'else' expression
fn parseIfExpr(self: *Parser) !*Expr {
    try self.advance(); // eat 'if'

    const cond = try self.parseExpression();

    switch (self.current) {
        .then => {},
        else => return error.ExpectedThen,
    }

    try self.advance(); // eat 'then'

    const then_expr = try self.parseExpression();

    switch (self.current) {
        .@"else" => {},
        else => return error.ExpectedElse,
    }

    try self.advance(); // eat 'else'

    const else_expr = try self.parseExpression();

    return self.makeExpr(.{
        .if_expr = .{
            .cond = cond,
            .then_expr = then_expr,
            .else_expr = else_expr,
        },
    });
}

// forexpr := 'for' identifier '=' expr ',' expr (',' expr)? 'in' expression
fn parseForExpr(self: *Parser) !*Expr {
    try self.advance(); // eat 'for'

    const var_name = switch (self.current) {
        .identifier => |name| name,
        else => return ParserError.ExpectedIdentifierAfterFor,
    };

    try self.advance(); // eat identifier

    if (!self.isChar('=')) {
        return ParserError.ExpectedEqualsAfterFor;
    }

    try self.advance(); // eat '='

    const start = try self.parseExpression();

    if (!self.isChar(',')) {
        return ParserError.ExpectedCommaAfterForStartValue;
    }

    try self.advance(); // eat ','

    const end = try self.parseExpression();

    var step: ?*Expr = null;
    if (self.isChar(',')) {
        try self.advance(); // eat ','
        step = try self.parseExpression();
    }

    if (self.current != .in) {
        return ParserError.ExpectedInAfterFor;
    }

    try self.advance(); // eat 'in'

    const body = try self.parseExpression();

    return self.makeExpr(.{ .for_expr = .{
        .var_name = var_name,
        .start = start,
        .end = end,
        .step = step,
        .body = body,
    } });
}

/// unary
///     ::= primary
///     ::= character unary
fn parseUnary(self: *Parser) !*Expr {
    switch (self.current) {
        .character => |op| {
            // These are not unary operator starts.
            if (op == '(' or op == ')' or op == ',' or op == ';') {
                return self.parsePrimary();
            }

            try self.advance(); // eat unary operator
            const operand = try self.parseUnary();

            return self.makeExpr(.{
                .unary = .{
                    .op = op,
                    .operand = operand,
                },
            });
        },
        else => return self.parsePrimary(),
    }
}

/// primary
///     ::= identifierexpr
///     ::= numberexpr
///     ::= parenexpr
fn parsePrimary(self: *Parser) ParserError!*Expr {
    return switch (self.current) {
        .identifier => self.parseIdentifierExpr(),
        .number => self.parseNumberExpr(),
        .character => |c| if (c == '(') self.parseParenExpr() else ParserError.ExpectedExpression,
        .@"if" => self.parseIfExpr(),
        .@"for" => self.parseForExpr(),
        .@"var" => self.parseVarExpr(),
        else => ParserError.ExpectedExpression,
    };
}

/// binoprhs ::= (binop unary)*
fn parseBinOpRHS(self: *Parser, expr_prec: i32, lhs_start: *Expr) !*Expr {
    var lhs = lhs_start;

    while (true) {
        const tok_prec = self.getTokPrecedence();

        if (tok_prec < expr_prec) {
            return lhs;
        }

        const bin_op = switch (self.current) {
            .character => |c| c,
            else => unreachable,
        };

        try self.advance(); // eat binary operator

        var rhs = try self.parseUnary();

        const next_prec = self.getTokPrecedence();
        if (tok_prec < next_prec) {
            rhs = try self.parseBinOpRHS(tok_prec + 1, rhs);
        }

        lhs = try self.makeExpr(.{
            .binary = .{
                .op = bin_op,
                .lhs = lhs,
                .rhs = rhs,
            },
        });
    }
}

/// expression ::= unary binoprhs
fn parseExpression(self: *Parser) !*Expr {
    const lhs = try self.parseUnary();
    return self.parseBinOpRHS(0, lhs);
}

/// prototype
///   ::= id '(' id* ')'
///   ::= unary character '(' id ')'
///   ::= binary character number? '(' id id ')'
pub fn parsePrototype(self: *Parser) !*Expr.Prototype {
    var function_name: []const u8 = undefined;
    var kind: Expr.Prototype.OperatorKind = .normal;
    var binary_precedence: i32 = 30;
    var expected_operand_count: usize = 0;

    switch (self.current) {
        .identifier => |name| {
            function_name = name;
            kind = .normal;
            expected_operand_count = 0;
            try self.advance(); // eat function name
        },
        .unary => {
            try self.advance(); // eat 'unary'

            const op = switch (self.current) {
                .character => |c| c,
                else => return error.ExpectedUnaryOperator,
            };

            function_name = try std.fmt.allocPrint(self.allocator, "unary{c}", .{op});
            kind = .unary;
            expected_operand_count = 1;

            try self.advance(); // eat operator
        },
        .binary => {
            try self.advance(); // eat 'binary'

            const op = switch (self.current) {
                .character => |c| c,
                else => return error.ExpectedBinaryOperator,
            };

            function_name = try std.fmt.allocPrint(self.allocator, "binary{c}", .{op});
            kind = .binary;
            expected_operand_count = 2;

            try self.advance(); // eat operator

            if (self.current == .number) {
                const precedence = switch (self.current) {
                    .number => |value| value,
                    else => unreachable,
                };

                if (precedence < 1 or precedence > 100) {
                    return error.InvalidPrecedence;
                }

                binary_precedence = @intFromFloat(precedence);
                try self.advance(); // eat precedence number
            }
        },
        else => return error.ExpectedFunctionName,
    }

    if (!self.isChar('(')) {
        return error.ExpectedOpenParenInPrototype;
    }

    try self.advance(); // eat '('

    var arg_names: std.ArrayList([]const u8) = .empty;
    defer arg_names.deinit(self.allocator);

    while (true) {
        switch (self.current) {
            .identifier => |name| {
                try arg_names.append(self.allocator, name);
                try self.advance(); // eat argument name
            },
            else => break,
        }
    }

    if (!self.isChar(')')) {
        return error.ExpectedCloseParenInPrototype;
    }

    try self.advance(); // eat ')'

    if (kind != .normal and arg_names.items.len != expected_operand_count) {
        return error.InvalidNumberOfOperatorOperands;
    }

    const owned_arg_names = try arg_names.toOwnedSlice(self.allocator);
    return self.makePrototype(.{
        .name = function_name,
        .args = owned_arg_names,
        .operator_kind = kind,
        .binary_precedence = binary_precedence,
    });
}

/// definition ::= 'def' prototype expression
pub fn parseDefinition(self: *Parser) !*Expr.Function {
    try self.advance(); // eat def

    const proto = try self.parsePrototype();
    const body = try self.parseExpression();

    return self.makeFunction(.{
        .proto = proto,
        .body = body,
    });
}

/// external ::= 'extern' prototype
pub fn parseExtern(self: *Parser) !*Expr.Prototype {
    try self.advance(); // eat extern
    return self.parsePrototype();
}

/// toplevelexpr ::= expression
pub fn parseTopLevelExpr(self: *Parser) !*Expr.Function {
    const expr = try self.parseExpression();
    const name = try std.fmt.allocPrint(
        self.allocator,
        "__anon_expr{d}",
        .{self.anonymous_function_count},
    );

    self.anonymous_function_count += 1;

    const proto = try self.makePrototype(.{
        .name = name,
        .args = &.{},
    });

    return self.makeFunction(.{
        .proto = proto,
        .body = expr,
    });
}
