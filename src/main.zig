const std = @import("std");

const Codegen = @import("codegen");
const Parser = @import("parser");
const Jit = @import("jit");
const build_options = @import("build_options");
const runtime = @import("runtime");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena;
    const allocator = arena.allocator();
    const source =
        \\extern putchard(char);
        \\extern printd(x);
        \\
        \\# Logical unary not.
        \\def unary!(v)
        \\  if v then
        \\    0
        \\  else
        \\    1;
        \\
        \\# Unary negate.
        \\def unary-(v)
        \\  0 - v;
        \\
        \\# Define > with same precedence as <.
        \\def binary> 10 (LHS RHS)
        \\  RHS < LHS;
        \\
        \\# Logical or. This does not short-circuit.
        \\def binary| 5 (LHS RHS)
        \\  if LHS then
        \\    1
        \\  else if RHS then
        \\    1
        \\  else
        \\    0;
        \\
        \\# Logical and. This does not short-circuit.
        \\def binary& 6 (LHS RHS)
        \\  if !LHS then
        \\    0
        \\  else
        \\    !!RHS;
        \\
        \\# Sequencing operator: evaluate x, then y, return y.
        \\def binary : 1 (x y)
        \\  y;
        \\
        \\printd(123) : printd(456) : printd(789);
        \\printd(!(1 < 2));
        \\printd(4 > 2);
        \\printd(1 & 0 | 1);
    ;
    var parser = try Parser.init(allocator, source);

    var jit = try Jit.init();
    defer jit.deinit();
    const host_symbols = runtime.hostSymbols();
    try jit.registerHostSymbols(&host_symbols);

    var codegen = try Codegen.initWithOptions(allocator, &jit, .{
        .dump_ir = build_options.dump_ir,
    });
    defer codegen.deinit();

    try codegen.process(&parser);
}
