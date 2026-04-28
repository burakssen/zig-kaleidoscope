const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const llvm_dep = b.dependency("llvm", .{
        .target = target,
        .optimize = optimize,
    });

    const llvm_mod = llvm_dep.module("llvm");
    const dump_ir = b.option(bool, "dump-ir", "Print generated LLVM IR while running") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "dump_ir", dump_ir);

    const lexer_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/lexer/lexer.zig"),
    });

    const parser_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/parser/parser.zig"),
        .imports = &.{
            .{ .name = "lexer", .module = lexer_mod },
        },
    });
    const jit_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/jit/jit.zig"),
        .imports = &.{
            .{ .name = "llvm", .module = llvm_mod },
        },
    });

    const runtime_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/runtime/runtime.zig"),
    });

    const codegen_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/codegen/codegen.zig"),
        .imports = &.{
            .{ .name = "llvm", .module = llvm_mod },
            .{ .name = "parser", .module = parser_mod },
            .{ .name = "jit", .module = jit_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "parser", .module = parser_mod },
            .{ .name = "codegen", .module = codegen_mod },
            .{ .name = "jit", .module = jit_mod },
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "kaleidoscope",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run kaleidoscope executable");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}
