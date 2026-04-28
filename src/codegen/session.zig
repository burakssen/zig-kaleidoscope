const std = @import("std");
const llvm = @import("llvm");
const CodegenError = @import("errors.zig").CodegenError;

pub fn startNewModule(self: anytype) CodegenError!void {
    if (self.context != null or self.module != null or self.builder != null) {
        return CodegenError.LLVMInitFailed;
    }

    const context = llvm.core.LLVMContextCreate() orelse return CodegenError.LLVMInitFailed;
    errdefer llvm.core.LLVMContextDispose(context);

    const module = llvm.core.LLVMModuleCreateWithNameInContext("KaleidoscopeJIT", context) orelse {
        return CodegenError.LLVMInitFailed;
    };
    errdefer llvm.core.LLVMDisposeModule(module);

    if (self.options.emit_object) {
        const target_data = self.target_data orelse return CodegenError.LLVMTargetMachineFailed;
        const target_triple = self.target_triple orelse return CodegenError.LLVMTargetMachineFailed;
        const data_layout = llvm.target.LLVMCopyStringRepOfTargetData(target_data);
        defer llvm.core.LLVMDisposeMessage(data_layout);

        llvm.core.LLVMSetDataLayout(module, data_layout);
        llvm.core.LLVMSetTarget(module, target_triple.ptr);
    } else {
        const jit = self.jit orelse return CodegenError.MissingJit;
        llvm.core.LLVMSetDataLayout(module, jit.dataLayout());
        llvm.core.LLVMSetTarget(module, jit.triple());
    }

    const builder = llvm.core.LLVMCreateBuilderInContext(context) orelse {
        return CodegenError.LLVMInitFailed;
    };
    errdefer llvm.core.LLVMDisposeBuilder(builder);

    self.context = context;
    self.module = module;
    self.builder = builder;
}

pub fn submitModuleToJitAndOpenNewModule(self: anytype) CodegenError!void {
    const tsm = try takeThreadSafeModule(self);
    const jit = self.jit orelse return CodegenError.MissingJit;
    try jit.addModule(tsm);
    try startNewModule(self);
}

pub fn currentModule(self: anytype) CodegenError!llvm.types.LLVMModuleRef {
    return self.module orelse CodegenError.NoCurrentModule;
}

pub fn currentBuilder(self: anytype) CodegenError!llvm.types.LLVMBuilderRef {
    return self.builder orelse CodegenError.NoCurrentModule;
}

pub fn doubleType(self: anytype) llvm.types.LLVMTypeRef {
    return llvm.core.LLVMDoubleTypeInContext(self.context.?);
}

pub fn cstr(self: anytype, text: []const u8) std.mem.Allocator.Error![:0]u8 {
    return self.allocator.dupeZ(u8, text);
}

pub fn optimizeFunction(function: llvm.types.LLVMValueRef) CodegenError!void {
    const options = llvm.transform.LLVMCreatePassBuilderOptions() orelse {
        return CodegenError.LLVMInitFailed;
    };
    defer llvm.transform.LLVMDisposePassBuilderOptions(options);

    llvm.transform.LLVMPassBuilderOptionsSetVerifyEach(options, 0);

    const err = llvm.transform.LLVMRunPassesOnFunction(
        function,
        "mem2reg,instcombine,reassociate,gvn,simplifycfg",
        null,
        options,
    );

    if (err != null) {
        return CodegenError.LLVMOptimizationFailed;
    }
}

fn takeThreadSafeModule(self: anytype) CodegenError!llvm.orc.LLVMOrcThreadSafeModuleRef {
    const context = self.context orelse return CodegenError.NoCurrentModule;
    const module = self.module orelse return CodegenError.NoCurrentModule;

    if (self.builder) |builder| {
        llvm.core.LLVMDisposeBuilder(builder);
        self.builder = null;
    }

    const tsc = llvm.orc.LLVMOrcCreateNewThreadSafeContextFromLLVMContext(context) orelse {
        return CodegenError.LLVMInitFailed;
    };
    defer llvm.orc.LLVMOrcDisposeThreadSafeContext(tsc);

    const tsm = llvm.orc.LLVMOrcCreateNewThreadSafeModule(module, tsc) orelse {
        return CodegenError.LLVMInitFailed;
    };

    self.context = null;
    self.module = null;

    return tsm;
}
