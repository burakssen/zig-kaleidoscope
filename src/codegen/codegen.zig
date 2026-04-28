const std = @import("std");
const llvm = @import("llvm");
const Parser = @import("parser");
const Jit = @import("jit");
const debug = @import("debug.zig");
const session = @import("session.zig");

pub const CodegenError = @import("errors.zig").CodegenError;

pub const Options = struct {
    dump_ir: bool = false,
    emit_object: bool = false,
    object_path: []const u8 = "output.o",
};

const Codegen = @This();

allocator: std.mem.Allocator,
jit: ?*Jit,
options: Options,

context: llvm.types.LLVMContextRef = null,
module: llvm.types.LLVMModuleRef = null,
builder: llvm.types.LLVMBuilderRef = null,
target_machine: llvm.types.LLVMTargetMachineRef = null,
target_data: llvm.types.LLVMTargetDataRef = null,
target_triple: ?[:0]u8 = null,

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

pub fn initObjectEmitter(allocator: std.mem.Allocator, options: Options) !Codegen {
    var self = Codegen{
        .allocator = allocator,
        .jit = null,
        .options = options,
        .named_values = .init(allocator),
        .function_protos = .init(allocator),
    };
    errdefer self.deinit();

    try self.initObjectTarget();
    try self.startNewModule();
    return self;
}

pub fn deinit(self: *Codegen) void {
    if (self.builder) |builder| llvm.core.LLVMDisposeBuilder(builder);
    if (self.module) |module| llvm.core.LLVMDisposeModule(module);
    if (self.context) |context| llvm.core.LLVMContextDispose(context);
    if (self.target_data) |target_data| llvm.target.LLVMDisposeTargetData(target_data);
    if (self.target_machine) |target_machine| llvm.target_machine.LLVMDisposeTargetMachine(target_machine);
    if (self.target_triple) |target_triple| self.allocator.free(target_triple);

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

fn initObjectTarget(self: *Codegen) CodegenError!void {
    llvm.target.LLVMInitializeAllTargetInfos();
    llvm.target.LLVMInitializeAllTargets();
    llvm.target.LLVMInitializeAllTargetMCs();
    llvm.target.LLVMInitializeAllAsmPrinters();
    llvm.target.LLVMInitializeAllAsmParsers();

    const default_triple_c = llvm.target_machine.LLVMGetDefaultTargetTriple();
    defer llvm.core.LLVMDisposeMessage(default_triple_c);

    const default_triple = std.mem.span(default_triple_c);
    const target_triple = if (std.mem.startsWith(u8, default_triple, "arm64-apple-darwin"))
        try std.fmt.allocPrintSentinel(self.allocator, "aarch64{s}", .{default_triple["arm64".len..]}, 0)
    else
        try self.allocator.dupeZ(u8, default_triple);
    errdefer self.allocator.free(target_triple);

    var target: llvm.types.LLVMTargetRef = null;
    var error_message: [*c]u8 = null;
    if (llvm.target_machine.LLVMGetTargetFromTriple(target_triple.ptr, &target, &error_message) != 0) {
        defer if (error_message != null) llvm.core.LLVMDisposeMessage(error_message);
        if (error_message != null) {
            std.debug.print("LLVM target lookup failed: {s}\n", .{std.mem.span(error_message)});
        }
        return CodegenError.LLVMTargetLookupFailed;
    }

    const target_machine = llvm.target_machine.LLVMCreateTargetMachine(
        target,
        target_triple.ptr,
        "generic",
        "",
        .LLVMCodeGenLevelDefault,
        .LLVMRelocPIC,
        .LLVMCodeModelDefault,
    ) orelse return CodegenError.LLVMTargetMachineFailed;
    errdefer llvm.target_machine.LLVMDisposeTargetMachine(target_machine);

    const target_data = llvm.target_machine.LLVMCreateTargetDataLayout(target_machine) orelse {
        return CodegenError.LLVMTargetMachineFailed;
    };
    errdefer llvm.target.LLVMDisposeTargetData(target_data);

    self.target_triple = target_triple;
    self.target_machine = target_machine;
    self.target_data = target_data;
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
            .eof => {
                if (self.options.emit_object) {
                    try self.emitObjectFile();
                }
                return;
            },
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

pub fn emitObjectFile(self: *Codegen) CodegenError!void {
    const module = try self.currentModule();
    const target_machine = self.target_machine orelse return CodegenError.LLVMTargetMachineFailed;

    const filename = try self.cstr(self.options.object_path);
    defer self.allocator.free(filename);

    var error_message: [*c]u8 = null;
    if (llvm.target_machine.LLVMTargetMachineEmitToFile(
        target_machine,
        module,
        filename.ptr,
        .LLVMObjectFile,
        &error_message,
    ) != 0) {
        defer if (error_message != null) llvm.core.LLVMDisposeMessage(error_message);
        if (error_message != null) {
            std.debug.print("LLVM object emission failed: {s}\n", .{std.mem.span(error_message)});
        }
        return CodegenError.LLVMObjectEmissionFailed;
    }

    std.debug.print("Wrote {s}\n", .{self.options.object_path});
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

    if (self.options.emit_object) return;

    try self.submitModuleToJitAndOpenNewModule();

    const jit = self.jit orelse return CodegenError.MissingJit;
    const address = jit.lookup(self.allocator, function_name) catch |err| {
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
        .if_expr => |if_expr| self.codegenIfExpr(if_expr),
        .for_expr => |for_expr| self.codegenForExpr(for_expr),
        .var_expr => |var_expr| self.codegenVarExpr(var_expr),
    };
}

fn codegenNumber(self: *Codegen, value: f64) !llvm.types.LLVMValueRef {
    return llvm.core.LLVMConstReal(self.doubleType(), value);
}

fn codegenVariable(self: *Codegen, name: []const u8) CodegenError!llvm.types.LLVMValueRef {
    const alloca = self.named_values.get(name) orelse {
        return CodegenError.UnknownVariableName;
    };

    const name_z = try self.cstr(name);
    defer self.allocator.free(name_z);

    return llvm.core.LLVMBuildLoad2(
        try self.currentBuilder(),
        self.doubleType(),
        alloca,
        name_z.ptr,
    ) orelse CodegenError.LLVMInitFailed;
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

    if (binary.op == '=') {
        const variable_name = switch (binary.lhs.*) {
            .variable => |name| name,
            else => return CodegenError.AssignmentDestinationMustBeVariable,
        };

        const value = try self.codegenExpr(binary.rhs);

        const alloca = self.named_values.get(variable_name) orelse {
            return CodegenError.UnknownVariableName;
        };

        _ = llvm.core.LLVMBuildStore(builder, value, alloca);
        return value;
    }

    var lhs = try self.codegenExpr(binary.lhs);
    const rhs = try self.codegenExpr(binary.rhs);

    return switch (binary.op) {
        '+' => llvm.core.LLVMBuildFAdd(builder, lhs, rhs, "addtmp") orelse CodegenError.LLVMInitFailed,
        '-' => llvm.core.LLVMBuildFSub(builder, lhs, rhs, "subtmp") orelse CodegenError.LLVMInitFailed,
        '*' => llvm.core.LLVMBuildFMul(builder, lhs, rhs, "multmp") orelse CodegenError.LLVMInitFailed,
        '<' => blk: {
            lhs = llvm.core.LLVMBuildFCmp(
                builder,
                .LLVMRealULT,
                lhs,
                rhs,
                "cmptmp",
            ) orelse return CodegenError.LLVMInitFailed;

            break :blk llvm.core.LLVMBuildUIToFP(
                builder,
                lhs,
                self.doubleType(),
                "booltmp",
            ) orelse return CodegenError.LLVMInitFailed;
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
        defer self.allocator.free(c_arg_name);
        llvm.core.LLVMSetValueName2(param, c_arg_name.ptr, arg_name.len);

        const alloca = try self.createEntryBlockAlloca(function, arg_name);
        _ = llvm.core.LLVMBuildStore(try self.currentBuilder(), param, alloca);

        try self.named_values.put(arg_name, alloca);
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

fn codegenIfExpr(self: *Codegen, if_expr: Parser.Expr.IfExpr) CodegenError!llvm.types.LLVMValueRef {
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
    const function = try self.currentFunction();

    const alloca = try self.createEntryBlockAlloca(function, for_expr.var_name);

    // Emit the start value before the loop variable is put into scope.
    const start_value = try self.codegenExpr(for_expr.start);
    _ = llvm.core.LLVMBuildStore(builder, start_value, alloca);

    const loop_bb = llvm.core.LLVMAppendBasicBlockInContext(
        self.context.?,
        function,
        "loop",
    ) orelse return CodegenError.LLVMInitFailed;

    _ = llvm.core.LLVMBuildBr(builder, loop_bb);
    llvm.core.LLVMPositionBuilderAtEnd(builder, loop_bb);

    const old_value = self.named_values.get(for_expr.var_name);
    try self.named_values.put(for_expr.var_name, alloca);

    // Emit the loop body.
    _ = try self.codegenExpr(for_expr.body);

    // Emit the step value, defaulting to 1.0.
    const step_value = if (for_expr.step) |step_expr|
        try self.codegenExpr(step_expr)
    else
        llvm.core.LLVMConstReal(self.doubleType(), 1.0);

    var end_cond = try self.codegenExpr(for_expr.end);
    end_cond = llvm.core.LLVMBuildFCmp(
        builder,
        .LLVMRealONE,
        end_cond,
        llvm.core.LLVMConstReal(self.doubleType(), 0.0),
        "loopcond",
    ) orelse return CodegenError.LLVMInitFailed;

    const current_var = llvm.core.LLVMBuildLoad2(
        builder,
        self.doubleType(),
        alloca,
        "curvar",
    ) orelse return CodegenError.LLVMInitFailed;

    const next_var = llvm.core.LLVMBuildFAdd(
        builder,
        current_var,
        step_value,
        "nextvar",
    ) orelse return CodegenError.LLVMInitFailed;

    _ = llvm.core.LLVMBuildStore(builder, next_var, alloca);

    const after_bb = llvm.core.LLVMAppendBasicBlockInContext(
        self.context.?,
        function,
        "afterloop",
    ) orelse return CodegenError.LLVMInitFailed;

    _ = llvm.core.LLVMBuildCondBr(builder, end_cond, loop_bb, after_bb);

    llvm.core.LLVMPositionBuilderAtEnd(builder, after_bb);

    if (old_value) |value| {
        try self.named_values.put(for_expr.var_name, value);
    } else {
        _ = self.named_values.remove(for_expr.var_name);
    }

    return llvm.core.LLVMConstReal(self.doubleType(), 0.0);}
fn createEntryBlockAlloca(
    self: *Codegen,
    function: llvm.types.LLVMValueRef,
    name: []const u8,
) CodegenError!llvm.types.LLVMValueRef {
    const entry = llvm.core.LLVMGetEntryBasicBlock(function) orelse {
        return CodegenError.LLVMInitFailed;
    };

    const tmp_builder = llvm.core.LLVMCreateBuilderInContext(self.context.?) orelse {
        return CodegenError.LLVMInitFailed;
    };
    defer llvm.core.LLVMDisposeBuilder(tmp_builder);

    if (llvm.core.LLVMGetFirstInstruction(entry)) |first_inst| {
        llvm.core.LLVMPositionBuilderBefore(tmp_builder, first_inst);
    } else {
        llvm.core.LLVMPositionBuilderAtEnd(tmp_builder, entry);
    }

    const name_z = try self.cstr(name);
    defer self.allocator.free(name_z);

    return llvm.core.LLVMBuildAlloca(
        tmp_builder,
        self.doubleType(),
        name_z.ptr,
    ) orelse CodegenError.LLVMInitFailed;
}

fn codegenVarExpr(self: *Codegen, var_expr: Parser.Expr.VarExpr) CodegenError!llvm.types.LLVMValueRef {
    const builder = try self.currentBuilder();
    const function = try self.currentFunction();

    var old_bindings: std.ArrayList(?llvm.types.LLVMValueRef) = .empty;
    defer old_bindings.deinit(self.allocator);

    for (var_expr.bindings) |binding| {
        // Emit initializer before the new variable shadows an existing name.
        const init_value = if (binding.init) |init_expr|
            try self.codegenExpr(init_expr)
        else
            llvm.core.LLVMConstReal(self.doubleType(), 0.0);

        const alloca = try self.createEntryBlockAlloca(function, binding.name);
        _ = llvm.core.LLVMBuildStore(builder, init_value, alloca);

        try old_bindings.append(self.allocator, self.named_values.get(binding.name));
        try self.named_values.put(binding.name, alloca);
    }

    const body_value = try self.codegenExpr(var_expr.body);

    for (var_expr.bindings, 0..) |binding, index| {
        if (old_bindings.items[index]) |old_value| {
            try self.named_values.put(binding.name, old_value);
        } else {
            _ = self.named_values.remove(binding.name);
        }
    }

    return body_value;
}
