const Expr = @import("expr.zig").Expr;

pub const PrecedenceTable = [256]i32;

pub fn defaults() PrecedenceTable {
    var result = [_]i32{-1} ** 256;
    result['<'] = 10;
    result['+'] = 20;
    result['-'] = 20;
    result['*'] = 40;
    return result;
}

pub fn registerPrototype(table: *PrecedenceTable, proto: *const Expr.Prototype) !void {
    if (!proto.isBinaryOp()) return;

    const precedence = proto.binary_precedence;
    if (precedence < 1 or precedence > 100) {
        return error.InvalidPrecedence;
    }

    table[proto.getOperatorName()] = precedence;
}
