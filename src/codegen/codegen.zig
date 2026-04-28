const std = @import("std");
const llvm = @import("llvm");
const Parser = @import("parser");
const Jit = @import("jit");
const debug = @import("debug.zig");
const session = @import("session.zig");

pub const CodegenError = @import("errors.zig").CodegenError;

pub const Options = struct {
    dump_ir: bool = false,
};

const Codegen = @This();

allocator: std.mem.Allocator,
jit: *Jit,
options: Options,

context: llvm.types.LLVMContextRef = null,
module: llvm.types.LLVMModuleRef = null,
builder: llvm.types.LLVMBuilderRef = null,

named_values: std.StringHashMap(llvm.types.LLVMValueRef),
function_protos: std.StringHashMap(*const Parser.Expr.Prototype),

pub fn init(allocator: std.mem.Allocator, jit: *Jit) !Codegen {
    return initWithOptions(allocator, jit, .{});
}

pub fn initWithOptions(allocator: std.mem.Allocator, jit: *Jit, options: Options) !Codegen {
    var self = Codegen{
        .allocator = allocator,
        .jit = jit,
        .options = options,
        .named_values = .init(allocator),
        .function_protos = .init(allocator),
    };

    try self.startNewModule();
    return self;
}

pub fn deinit(self: *Codegen) void {
    if (self.builder) |builder| llvm.core.LLVMDisposeBuilder(builder);
    if (self.module) |module| llvm.core.LLVMDisposeModule(module);
    if (self.context) |context| llvm.core.LLVMContextDispose(context);

    self.named_values.deinit();
    self.function_protos.deinit();
}

pub fn startNewModule(self: *Codegen) !void {
    return session.startNewModule(self);
}
pub fn submitModuleToJitAndOpenNewModule(self: *Codegen) !void {
    return session.submitModuleToJitAndOpenNewModule(self);
}

fn optimizeFunction(_: *Codegen, function: llvm.types.LLVMValueRef) CodegenError!void {
    return session.optimizeFunction(function);
}

fn currentModule(self: *Codegen) !llvm.types.LLVMModuleRef {
    return session.currentModule(self);
}

fn currentBuilder(self: *Codegen) !llvm.types.LLVMBuilderRef {
    return session.currentBuilder(self);
}

fn doubleType(self: *Codegen) llvm.types.LLVMTypeRef {
    return session.doubleType(self);
}

fn cstr(self: *Codegen, text: []const u8) ![:0]u8 {
    return session.cstr(self, text);
}

pub fn dumpValue(_: *Codegen, value: llvm.types.LLVMValueRef) void {
    debug.dumpValue(value);
}

pub fn dumpModule(self: *Codegen) void {
    debug.dumpModule(self.module);
}

pub fn process(self: *Codegen, parser: *Parser) !void {
    while (true) {
        switch (parser.current) {
            .eof => return,
            .def => try self.handleDefinition(parser),
            .@"extern" => try self.handleExtern(parser),
            .character => |c| {
                if (c == ';') {
                    try parser.advance();
                } else {
                    try self.handleTopLevelExpression(parser);
                }
            },
            else => try self.handleTopLevelExpression(parser),
        }
    }
}

fn handleDefinition(self: *Codegen, parser: *Parser) !void {
    const function_ast = parser.parseDefinition() catch |err| {
        std.debug.print("Error while parsing definition: {s}\n", .{@errorName(err)});
        try parser.advance();
        return;
    };

    const function = self.codegenFunction(function_ast) catch |err| {
        std.debug.print("Error while generating function: {s}\n", .{@errorName(err)});
        return;
    };

    try parser.registerPrototype(function_ast.proto);

    if (self.options.dump_ir) {
        std.debug.print("Read function definition:\n", .{});
        self.dumpValue(function);
    }
}

fn handleExtern(self: *Codegen, parser: *Parser) !void {
    const proto = parser.parseExtern() catch |err| {
        std.debug.print("Error while parsing extern: {s}\n", .{@errorName(err)});
        try parser.advance();
        return;
    };

    const function = self.codegenExtern(proto) catch |err| {
        std.debug.print("Error while generating extern: {s}\n", .{@errorName(err)});
        return;
    };

    try parser.registerPrototype(proto);

    if (self.options.dump_ir) {
        std.debug.print("Read extern:\n", .{});
        self.dumpValue(function);
    }
}

fn handleTopLevelExpression(self: *Codegen, parser: *Parser) !void {
    const function_ast = parser.parseTopLevelExpr() catch |err| {
        std.debug.print("Error while parsing top-level expression: {s}\n", .{@errorName(err)});
        try parser.advance();
        return;
    };

    const function_name = function_ast.proto.name;

    const function = self.codegenFunction(function_ast) catch |err| {
        std.debug.print("Error while generating top-level expression: {s}\n", .{@errorName(err)});
        return;
    };

    if (self.options.dump_ir) {
        std.debug.print("Read top-level expression:\n", .{});
        self.dumpValue(function);
    }

    try self.submitModuleToJitAndOpenNewModule();

    const address = self.jit.lookup(self.allocator, function_name) catch |err| {
        std.debug.print("Error while looking up generated function: {s}\n", .{@errorName(err)});
        return;
    };

    const MainFn = *const fn () callconv(.c) f64;
    const compiled_fn: MainFn = @ptrFromInt(address);
    const result = compiled_fn();
    std.debug.print("Evaluated to {d}\n", .{result});
}

pub fn codegenExpr(self: *Codegen, expr: *const Parser.Expr) CodegenError!llvm.types.LLVMValueRef {
    return switch (expr.*) {
        .number => |value| self.codegenNumber(value),
        .variable => |name| self.codegenVariable(name),
        .unary => |unary| self.codegenUnary(unary),
        .binary => |binary| self.codegenBinary(binary),
        .call => |call| self.codegenCall(call),
        .if_expr => |if_expr| self.codegenIf(if_expr),
        .for_expr => |for_expr| self.codegenForExpr(for_expr),

        // If Chapter 7 is already present:
        // .var_expr => |var_expr| self.codegenVar(var_expr),
    };
}

fn codegenNumber(self: *Codegen, value: f64) !llvm.types.LLVMValueRef {
    return llvm.core.LLVMConstReal(self.doubleType(), value);
}

fn codegenVariable(self: *Codegen, name: []const u8) !llvm.types.LLVMValueRef {
    if (self.named_values.get(name)) |value| {
        return value;
    }

    return CodegenError.UnknownVariableName;
}

fn codegenUnary(self: *Codegen, unary: Parser.Expr.UnaryExpr) CodegenError!llvm.types.LLVMValueRef {
    const operand = try self.codegenExpr(unary.operand);

    const function_name = try std.fmt.allocPrint(self.allocator, "unary{c}", .{unary.op});
    defer self.allocator.free(function_name);

    const callee = (try self.getFunction(function_name)) orelse {
        return CodegenError.UnknownUnaryOperator;
    };

    var args = [_]llvm.types.LLVMValueRef{operand};
    const callee_type = llvm.core.LLVMGlobalGetValueType(callee);

    return llvm.core.LLVMBuildCall2(
        try self.currentBuilder(),
        callee_type,
        callee,
        &args,
        1,
        "unop",
    ) orelse CodegenError.LLVMInitFailed;
}

fn codegenBinary(self: *Codegen, binary: Parser.Expr.BinaryExpr) CodegenError!llvm.types.LLVMValueRef {
    const builder = try self.currentBuilder();

    var lhs = try self.codegenExpr(binary.lhs);
    const rhs = try self.codegenExpr(binary.rhs);

    return switch (binary.op) {
        '+' => llvm.core.LLVMBuildFAdd(builder, lhs, rhs, "addtmp") orelse CodegenError.LLVMInitFailed,
        '-' => llvm.core.LLVMBuildFSub(builder, lhs, rhs, "subtmp") orelse CodegenError.LLVMInitFailed,
        '*' => llvm.core.LLVMBuildFMul(builder, lhs, rhs, "multmp") orelse CodegenError.LLVMInitFailed,
        '<' => blk: {
            lhs = llvm.core.LLVMBuildFCmp(builder, .LLVMRealULT, lhs, rhs, "cmptmp") orelse {
                return CodegenError.LLVMInitFailed;
            };

            break :blk llvm.core.LLVMBuildUIToFP(builder, lhs, self.doubleType(), "booltmp") orelse {
                return CodegenError.LLVMInitFailed;
            };
        },
        else => self.codegenUserBinary(binary.op, lhs, rhs),
    };
}

fn codegenUserBinary(
    self: *Codegen,
    op: u8,
    lhs: llvm.types.LLVMValueRef,
    rhs: llvm.types.LLVMValueRef,
) CodegenError!llvm.types.LLVMValueRef {
    const function_name = try std.fmt.allocPrint(self.allocator, "binary{c}", .{op});
    defer self.allocator.free(function_name);

    const callee = (try self.getFunction(function_name)) orelse {
        return CodegenError.UnknownBinaryOperator;
    };

    var args = [_]llvm.types.LLVMValueRef{ lhs, rhs };
    const callee_type = llvm.core.LLVMGlobalGetValueType(callee);

    return llvm.core.LLVMBuildCall2(
        try self.currentBuilder(),
        callee_type,
        callee,
        &args,
        2,
        "binop",
    ) orelse CodegenError.LLVMInitFailed;
}

fn getFunction(self: *Codegen, name: []const u8) CodegenError!?llvm.types.LLVMValueRef {
    const module = try self.currentModule();

    const function_name = try self.cstr(name);
    defer self.allocator.free(function_name);

    if (llvm.core.LLVMGetNamedFunction(module, function_name.ptr)) |existing| {
        return existing;
    }

    if (self.function_protos.get(name)) |proto| {
        return try self.codegenPrototype(proto);
    }

    return null;
}

fn codegenCall(self: *Codegen, call: Parser.Expr.CallExpr) CodegenError!llvm.types.LLVMValueRef {
    const callee = (try self.getFunction(call.callee)) orelse {
        return CodegenError.UnknownFunctionReferenced;
    };

    if (@as(usize, @intCast(llvm.core.LLVMCountParams(callee))) != call.args.len) {
        return CodegenError.IncorrectArgumentCount;
    }

    var args: std.ArrayList(llvm.types.LLVMValueRef) = .empty;
    defer args.deinit(self.allocator);

    for (call.args) |arg_expr| {
        const arg_value = try self.codegenExpr(arg_expr);
        try args.append(self.allocator, arg_value);
    }

    const args_ptr = if (args.items.len == 0) null else args.items.ptr;
    const callee_type = llvm.core.LLVMGlobalGetValueType(callee);

    return llvm.core.LLVMBuildCall2(
        self.builder,
        callee_type,
        callee,
        args_ptr,
        @intCast(args.items.len),
        "calltmp",
    );
}

pub fn codegenExtern(self: *Codegen, proto: *const Parser.Expr.Prototype) CodegenError!llvm.types.LLVMValueRef {
    try self.function_protos.put(proto.name, proto);
    return self.codegenPrototype(proto);
}

pub fn codegenPrototype(self: *Codegen, proto: *const Parser.Expr.Prototype) !llvm.types.LLVMValueRef {
    const function_name = try self.cstr(proto.name);
    if (llvm.core.LLVMGetNamedFunction(self.module, function_name.ptr)) |existing| {
        return existing;
    }

    const arg_types = try self.allocator.alloc(llvm.types.LLVMTypeRef, proto.args.len);
    defer self.allocator.free(arg_types);
    @memset(arg_types, self.doubleType());

    const arg_types_ptr = if (arg_types.len == 0) null else arg_types.ptr;
    const function_type = llvm.core.LLVMFunctionType(
        self.doubleType(),
        arg_types_ptr,
        @intCast(arg_types.len),
        0,
    );

    const function = llvm.core.LLVMAddFunction(self.module, function_name.ptr, function_type) orelse {
        return CodegenError.LLVMInitFailed;
    };

    for (proto.args, 0..) |arg_name, index| {
        const param = llvm.core.LLVMGetParam(function, @intCast(index));
        const c_arg_name = try self.cstr(arg_name);
        llvm.core.LLVMSetValueName2(param, c_arg_name.ptr, arg_name.len);
    }

    return function;
}

pub fn codegenFunction(self: *Codegen, function_ast: *const Parser.Expr.Function) !llvm.types.LLVMValueRef {
    try self.function_protos.put(function_ast.proto.name, function_ast.proto);

    const function = (try self.getFunction(function_ast.proto.name)) orelse {
        return CodegenError.LLVMInitFailed;
    };

    if (llvm.core.LLVMCountBasicBlocks(function) != 0) {
        return CodegenError.FunctionRedefinition;
    }
    const entry = llvm.core.LLVMAppendBasicBlockInContext(self.context, function, "entry") orelse {
        return CodegenError.LLVMInitFailed;
    };

    llvm.core.LLVMPositionBuilderAtEnd(self.builder, entry);

    self.named_values.clearRetainingCapacity();

    for (function_ast.proto.args, 0..) |arg_name, index| {
        const param = llvm.core.LLVMGetParam(function, @intCast(index));
        const c_arg_name = try self.cstr(arg_name);
        llvm.core.LLVMSetValueName2(param, c_arg_name.ptr, arg_name.len);
        try self.named_values.put(arg_name, param);
    }

    const return_value = self.codegenExpr(function_ast.body) catch |err| {
        llvm.core.LLVMDeleteFunction(function);
        return err;
    };

    _ = llvm.core.LLVMBuildRet(self.builder, return_value);

    if (llvm.analysis.LLVMVerifyFunction(function, .LLVMPrintMessageAction) != 0) {
        llvm.core.LLVMDeleteFunction(function);
        return CodegenError.InvalidFunction;
    }

    try self.optimizeFunction(function);

    return function;
}

fn currentFunction(self: *Codegen) CodegenError!llvm.types.LLVMValueRef {
    const builder = try self.currentBuilder();
    const insert_block = llvm.core.LLVMGetInsertBlock(builder) orelse {
        return CodegenError.NoCurrentModule;
    };

    return llvm.core.LLVMGetBasicBlockParent(insert_block) orelse {
        return CodegenError.NoCurrentModule;
    };
}

fn codegenIf(self: *Codegen, if_expr: Parser.Expr.IfExpr) CodegenError!llvm.types.LLVMValueRef {
    const builder = try self.currentBuilder();

    var cond_value = try self.codegenExpr(if_expr.cond);

    cond_value = llvm.core.LLVMBuildFCmp(
        builder,
        .LLVMRealONE,
        cond_value,
        llvm.core.LLVMConstReal(self.doubleType(), 0.0),
        "ifcond",
    );

    const function = try self.currentFunction();

    const then_bb = llvm.core.LLVMAppendBasicBlockInContext(
        self.context,
        function,
        "then",
    ) orelse return CodegenError.LLVMInitFailed;

    const else_bb = llvm.core.LLVMCreateBasicBlockInContext(
        self.context,
        "else",
    ) orelse return CodegenError.LLVMInitFailed;

    const merge_bb = llvm.core.LLVMCreateBasicBlockInContext(
        self.context,
        "ifcont",
    ) orelse return CodegenError.LLVMInitFailed;

    _ = llvm.core.LLVMBuildCondBr(builder, cond_value, then_bb, else_bb);

    // Emit then block.
    llvm.core.LLVMPositionBuilderAtEnd(builder, then_bb);
    const then_value = try self.codegenExpr(if_expr.then_expr);
    _ = llvm.core.LLVMBuildBr(builder, merge_bb);

    const actual_then_bb = llvm.core.LLVMGetInsertBlock(builder) orelse {
        return CodegenError.LLVMInitFailed;
    };

    // Emit else block.
    llvm.core.LLVMAppendExistingBasicBlock(function, else_bb);
    llvm.core.LLVMPositionBuilderAtEnd(builder, else_bb);

    const else_value = try self.codegenExpr(if_expr.else_expr);
    _ = llvm.core.LLVMBuildBr(builder, merge_bb);

    const actual_else_bb = llvm.core.LLVMGetInsertBlock(builder) orelse {
        return CodegenError.LLVMInitFailed;
    };

    // Emit merge block.
    llvm.core.LLVMAppendExistingBasicBlock(function, merge_bb);
    llvm.core.LLVMPositionBuilderAtEnd(builder, merge_bb);

    const phi = llvm.core.LLVMBuildPhi(builder, self.doubleType(), "iftmp") orelse {
        return CodegenError.LLVMInitFailed;
    };

    var incoming_values = [_]llvm.types.LLVMValueRef{ then_value, else_value };
    var incoming_blocks = [_]llvm.types.LLVMBasicBlockRef{ actual_then_bb, actual_else_bb };

    llvm.core.LLVMAddIncoming(
        phi,
        &incoming_values,
        &incoming_blocks,
        incoming_values.len,
    );

    return phi;
}

fn codegenForExpr(self: *Codegen, for_expr: Parser.Expr.ForExpr) CodegenError!llvm.types.LLVMValueRef {
    const builder = try self.currentBuilder();

    // Emit the start expression before the loop variable is in scope.
    const start_value = try self.codegenExpr(for_expr.start);

    const function = try self.currentFunction();

    const preheader_bb = llvm.core.LLVMGetInsertBlock(builder) orelse {
        return CodegenError.LLVMInitFailed;
    };

    const loop_bb = llvm.core.LLVMAppendBasicBlockInContext(
        self.context,
        function,
        "loop",
    ) orelse return CodegenError.LLVMInitFailed;

    // Explicit fallthrough from current block to loop block.
    _ = llvm.core.LLVMBuildBr(builder, loop_bb);

    // Start insertion in the loop block.
    llvm.core.LLVMPositionBuilderAtEnd(builder, loop_bb);

    const var_name_z = try self.cstr(for_expr.var_name);
    defer self.allocator.free(var_name_z);

    const variable = llvm.core.LLVMBuildPhi(
        builder,
        self.doubleType(),
        var_name_z.ptr,
    ) orelse return CodegenError.LLVMInitFailed;

    var start_values = [_]llvm.types.LLVMValueRef{start_value};
    var start_blocks = [_]llvm.types.LLVMBasicBlockRef{preheader_bb};
    llvm.core.LLVMAddIncoming(variable, &start_values, &start_blocks, 1);

    // The loop variable shadows any existing variable with the same name.
    const old_value = self.named_values.get(for_expr.var_name);
    try self.named_values.put(for_expr.var_name, variable);

    // Emit the body. The value is ignored, but errors still matter.
    _ = try self.codegenExpr(for_expr.body);

    // Emit the step value, defaulting to 1.0.
    const step_value = if (for_expr.step) |step_expr|
        try self.codegenExpr(step_expr)
    else
        llvm.core.LLVMConstReal(self.doubleType(), 1.0);

    const next_var = llvm.core.LLVMBuildFAdd(
        builder,
        variable,
        step_value,
        "nextvar",
    );

    // Compute the loop condition.
    var end_cond = try self.codegenExpr(for_expr.end);
    end_cond = llvm.core.LLVMBuildFCmp(
        builder,
        .LLVMRealONE,
        end_cond,
        llvm.core.LLVMConstReal(self.doubleType(), 0.0),
        "loopcond",
    );

    const loop_end_bb = llvm.core.LLVMGetInsertBlock(builder) orelse {
        return CodegenError.LLVMInitFailed;
    };

    const after_bb = llvm.core.LLVMAppendBasicBlockInContext(
        self.context,
        function,
        "afterloop",
    ) orelse return CodegenError.LLVMInitFailed;

    _ = llvm.core.LLVMBuildCondBr(builder, end_cond, loop_bb, after_bb);

    // Add the backedge value to the induction-variable PHI.
    var next_values = [_]llvm.types.LLVMValueRef{next_var};
    var next_blocks = [_]llvm.types.LLVMBasicBlockRef{loop_end_bb};
    llvm.core.LLVMAddIncoming(variable, &next_values, &next_blocks, 1);

    // Continue inserting after the loop.
    llvm.core.LLVMPositionBuilderAtEnd(builder, after_bb);

    // Restore shadowed variable.
    if (old_value) |value| {
        try self.named_values.put(for_expr.var_name, value);
    } else {
        _ = self.named_values.remove(for_expr.var_name);
    }

    // for expressions always evaluate to 0.0.
    return llvm.core.LLVMConstReal(self.doubleType(), 0.0);
}
