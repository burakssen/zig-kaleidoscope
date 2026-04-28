const std = @import("std");
const llvm = @import("llvm");

pub const JitError = error{
    LLVMInitFailed,
    LLVMError,
    NullMaterializationUnit,
    SymbolLookupFailed,
} || std.mem.Allocator.Error;

pub fn checkLlvmError(err: llvm.types.LLVMErrorRef) JitError!void {
    if (err) |actual| {
        const raw_msg = llvm.errors.LLVMGetErrorMessage(actual);

        if (raw_msg) |m| {
            const msg = @as([*:0]u8, @ptrCast(m));
            defer llvm.errors.LLVMDisposeErrorMessage(msg);
            std.debug.print("LLVM error: {s}\n", .{std.mem.span(msg)});
        }

        return JitError.LLVMError;
    }
}

const Jit = @This();

ref: llvm.types.LLVMOrcLLJITRef,

pub fn init() !Jit {
    // More robust than only LLVMInitializeNativeTarget on macOS/Apple Silicon.
    llvm.target.LLVMInitializeAllTargetInfos();
    llvm.target.LLVMInitializeAllTargets();
    llvm.target.LLVMInitializeAllTargetMCs();
    llvm.target.LLVMInitializeAllAsmPrinters();
    llvm.target.LLVMInitializeAllAsmParsers();

    var jtmb: llvm.orc.LLVMOrcJITTargetMachineBuilderRef = null;
    try checkLlvmError(llvm.orc.LLVMOrcJITTargetMachineBuilderDetectHost(&jtmb));

    const target_machine_builder = jtmb orelse return JitError.LLVMInitFailed;

    // On Apple Silicon, normalize arm64-* to aarch64-*.
    const detected_triple_c = llvm.orc.LLVMOrcJITTargetMachineBuilderGetTargetTriple(
        target_machine_builder,
    );
    defer llvm.core.LLVMDisposeMessage(detected_triple_c);

    const detected_triple = std.mem.span(detected_triple_c);

    var normalized_triple: ?[:0]u8 = null;
    defer if (normalized_triple) |t| std.heap.page_allocator.free(t);

    if (std.mem.startsWith(u8, detected_triple, "arm64-apple-darwin")) {
        normalized_triple = try std.fmt.allocPrintSentinel(
            std.heap.page_allocator,
            "aarch64{s}",
            .{detected_triple["arm64".len..]},
            0,
        );

        llvm.orc.LLVMOrcJITTargetMachineBuilderSetTargetTriple(
            target_machine_builder,
            normalized_triple.?.ptr,
        );
    }

    const builder = llvm.jit.LLVMOrcCreateLLJITBuilder() orelse {
        llvm.orc.LLVMOrcDisposeJITTargetMachineBuilder(target_machine_builder);
        return JitError.LLVMInitFailed;
    };

    // Ownership of target_machine_builder is transferred to the LLJIT builder.
    llvm.jit.LLVMOrcLLJITBuilderSetJITTargetMachineBuilder(
        builder,
        target_machine_builder,
    );

    var result: llvm.types.LLVMOrcLLJITRef = null;

    // Ownership of builder is transferred to LLVMOrcCreateLLJIT.
    try checkLlvmError(llvm.jit.LLVMOrcCreateLLJIT(&result, builder));

    const jit_ref = result orelse return JitError.LLVMInitFailed;

    var generator: llvm.orc.LLVMOrcDefinitionGeneratorRef = null;
    try checkLlvmError(llvm.orc.LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(
        &generator,
        llvm.jit.LLVMOrcLLJITGetGlobalPrefix(jit_ref),
        null,
        null,
    ));

    llvm.orc.LLVMOrcJITDylibAddGenerator(
        llvm.jit.LLVMOrcLLJITGetMainJITDylib(jit_ref),
        generator,
    );

    return .{ .ref = jit_ref };
}
pub fn deinit(self: *Jit) void {
    if (self.ref) |jit_ref| {
        checkLlvmError(llvm.jit.LLVMOrcDisposeLLJIT(jit_ref)) catch {};
        self.ref = null;
    }
}

pub fn addModule(self: *Jit, module: llvm.orc.LLVMOrcThreadSafeModuleRef) JitError!void {
    try checkLlvmError(llvm.jit.LLVMOrcLLJITAddLLVMIRModule(
        self.ref,
        llvm.jit.LLVMOrcLLJITGetMainJITDylib(self.ref),
        module,
    ));
}

pub fn registerHostSymbols(self: *Jit, symbols: anytype) JitError!void {
    var pairs = try std.heap.page_allocator.alloc(llvm.orc.LLVMOrcCSymbolMapPair, symbols.len);
    defer std.heap.page_allocator.free(pairs);

    for (symbols, 0..) |symbol, index| {
        const name_z = try std.heap.page_allocator.dupeZ(u8, symbol.name);
        defer std.heap.page_allocator.free(name_z);

        pairs[index] = .{
            .Name = llvm.jit.LLVMOrcLLJITMangleAndIntern(self.ref, name_z.ptr),
            .Sym = .{
                .Address = @intCast(symbol.address),
                .Flags = callableExportedFlags(),
            },
        };
    }

    const materialization_unit = llvm.orc.LLVMOrcAbsoluteSymbols(pairs.ptr, pairs.len) orelse {
        return JitError.NullMaterializationUnit;
    };

    try checkLlvmError(llvm.orc.LLVMOrcJITDylibDefine(
        llvm.jit.LLVMOrcLLJITGetMainJITDylib(self.ref),
        materialization_unit,
    ));
}

pub fn lookup(self: *Jit, allocator: std.mem.Allocator, name: []const u8) JitError!usize {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    var address: llvm.orc.LLVMOrcExecutorAddress = 0;
    try checkLlvmError(llvm.jit.LLVMOrcLLJITLookup(
        self.ref,
        &address,
        name_z.ptr,
    ));

    if (address == 0) return JitError.SymbolLookupFailed;
    return @intCast(address);
}

pub fn dataLayout(self: *const Jit) [*c]const u8 {
    return llvm.jit.LLVMOrcLLJITGetDataLayoutStr(self.ref);
}

pub fn triple(self: *const Jit) [*c]const u8 {
    return llvm.jit.LLVMOrcLLJITGetTripleString(self.ref);
}

fn callableExportedFlags() llvm.orc.LLVMJITSymbolFlags {
    return .{
        .GenericFlags = @intCast(@intFromEnum(llvm.orc.LLVMJITSymbolGenericFlags.LLVMJITSymbolGenericFlagsCallable) |
            @intFromEnum(llvm.orc.LLVMJITSymbolGenericFlags.LLVMJITSymbolGenericFlagsExported)),
        .TargetFlags = 0,
    };
}
