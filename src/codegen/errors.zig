const std = @import("std");
const Jit = @import("jit");

pub const CodegenError = error{
    LLVMInitFailed,
    NoCurrentModule,
    UnknownVariableName,
    InvalidBinaryOperator,
    UnknownFunctionReferenced,
    IncorrectArgumentCount,
    FunctionRedefinition,
    InvalidFunction,
    LLVMOptimizationFailed,
    UnknownUnaryOperator,
    UnknownBinaryOperator,
    AssignmentDestinationMustBeVariable,
} || std.mem.Allocator.Error || Jit.JitError;
