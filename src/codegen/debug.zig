const std = @import("std");
const llvm = @import("llvm");

pub fn dumpValue(value: llvm.types.LLVMValueRef) void {
    llvm.core.LLVMDumpValue(value);
}

pub fn dumpModule(module: llvm.types.LLVMModuleRef) void {
    const text = llvm.core.LLVMPrintModuleToString(module);
    if (text) |ptr| {
        defer llvm.core.LLVMDisposeMessage(ptr);
        std.debug.print("{s}\n", .{std.mem.span(ptr)});
    }
}
