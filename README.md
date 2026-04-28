# kaleidoscope

A Zig implementation of the LLVM Kaleidoscope language pipeline. The project
lexes and parses a small expression language, lowers it to LLVM IR, and runs it
through LLVM ORC JIT.

## Features

- Lexer and parser for the Kaleidoscope language.
- Numeric expressions, variables, function calls, and function definitions.
- External function declarations.
- User-defined unary and binary operators with custom precedence.
- `if then else` expressions.
- `for` loop expressions.
- LLVM IR generation and optimization.
- LLVM ORC JIT execution.
- Small host runtime with `putchard` and `printd`.

## Requirements

- Zig 0.16.0 or newer.
- The LLVM Zig dependency declared in `build.zig.zon`.

Zig resolves the project dependency during build.

## Build

```sh
zig build
```

## Run

```sh
zig build run
```

The executable currently runs the embedded sample program in `src/main.zig`.
It does not read from a file or expose a REPL yet.

Expected output:

```text
123
456
789
Evaluated to 0
0
Evaluated to 0
1
Evaluated to 0
1
Evaluated to 0
```

## Debug IR

Print generated LLVM IR while running:

```sh
zig build run -Ddump-ir=true
```

## Project Layout

- `src/lexer`: tokenization.
- `src/parser`: AST definitions, parser, and operator precedence handling.
- `src/codegen`: LLVM IR generation, optimization, and module management.
- `src/jit`: LLVM ORC JIT setup, symbol registration, and lookup.
- `src/runtime`: host functions exported to JITed code.
- `src/main.zig`: embedded sample program and compiler/JIT wiring.

## License

MIT. See `LICENCE`.
