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
        \\# Chapter 6 sequencing operator.
        \\def binary : 1 (x y) y;
        \\
        \\def fib(x)
        \\  if x < 3 then
        \\    1
        \\  else
        \\    fib(x - 1) + fib(x - 2);
        \\
        \\fib(10);
        \\
        \\def test(x)
        \\  printd(x) :
        \\  x = 4 :
        \\  printd(x);
        \\
        \\test(123);
        \\
        \\def fibi(x)
        \\  var a = 1, b = 1, c in
        \\  (for i = 3, i < x in
        \\     c = a + b :
        \\     a = b :
        \\     b = c) :
        \\  b;
        \\
        \\fibi(10);
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
