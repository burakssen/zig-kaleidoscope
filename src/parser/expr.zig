pub const Expr = union(enum) {
    number: f64,
    variable: []const u8,
    unary: UnaryExpr,
    binary: BinaryExpr,
    call: CallExpr,
    if_expr: IfExpr,
    for_expr: ForExpr,
    var_expr: VarExpr,

    pub const UnaryExpr = struct {
        op: u8,
        operand: *Expr,
    };

    pub const BinaryExpr = struct {
        op: u8,
        lhs: *Expr,
        rhs: *Expr,
    };

    pub const CallExpr = struct {
        callee: []const u8,
        args: []const *Expr,
    };

    pub const IfExpr = struct {
        cond: *Expr,
        then_expr: *Expr,
        else_expr: *Expr,
    };

    pub const ForExpr = struct {
        var_name: []const u8,
        start: *Expr,
        end: *Expr,
        step: ?*Expr,
        body: *Expr,
    };

    pub const VarBinding = struct {
        name: []const u8,
        init: ?*Expr,
    };

    pub const VarExpr = struct {
        bindings: []const VarBinding,
        body: *Expr,
    };

    pub const Prototype = struct {
        name: []const u8,
        args: []const []const u8,
        operator_kind: OperatorKind = .normal,
        binary_precedence: i32 = 0,

        pub const OperatorKind = enum {
            normal,
            unary,
            binary,
        };

        pub fn isUnaryOp(self: *const Prototype) bool {
            return self.operator_kind == .unary and self.args.len == 1;
        }

        pub fn isBinaryOp(self: *const Prototype) bool {
            return self.operator_kind == .binary and self.args.len == 2;
        }

        pub fn getOperatorName(self: *const Prototype) u8 {
            return self.name[self.name.len - 1];
        }
    };

    pub const Function = struct {
        proto: *Prototype,
        body: *Expr,
    };
};
