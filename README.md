# zsexp

An S-expression language with Zig-like semantics that compiles to WebAssembly.

## What is this?

zsexp is a tiny language that combines the trivial parsing of S-expressions with Zig's low-level semantics (no GC, explicit types, value semantics) — and compiles directly to WebAssembly binary. The compiler is ~700 lines of Zig.

```lisp
;; Zig:  fn factorial(n: i32) i32 { ... }
(fn factorial ((n i32)) i32
  (var result i32 1)
  (var i i32 1)
  (while (<= i n)
    (set result (* result i))
    (set i (+ i 1)))
  result)

(export factorial)
```

Compiles to a 83-byte `.wasm` file.

## Quick Start

```bash
# Build the compiler
zig build

# Compile an example
./zig-out/bin/zsexp examples/factorial.sexpr out.wasm

# Run with Node.js
node -e "const fs=require('fs'); WebAssembly.instantiate(fs.readFileSync('out.wasm')).then(m => console.log(m.instance.exports.factorial(10)))"
# => 3628800
```

## Language Reference

### Types

WASM native types: `i32`, `i64`, `f32`, `f64`.

### Functions

```lisp
(fn name ((param1 type1) (param2 type2)) return_type
  body...)

(export name)  ;; export a function to the host
```

The last expression in the body is the return value.

### Variables

```lisp
(var x i32 42)      ;; declare local, initialize to 42
(set x (+ x 1))    ;; mutate local
```

### Arithmetic & Comparison

```lisp
(+ a b)   (- a b)   (* a b)   (/ a b)   (% a b)
(== a b)  (!= a b)  (< a b)   (> a b)   (<= a b)  (>= a b)
(and a b) (or a b)  (xor a b) (shl a b) (shr a b)
```

Operators dispatch to the correct WASM opcode based on operand type.

### Control Flow

```lisp
;; if-expression (with else → produces a value)
(if (> a b) a b)

;; if-statement (no else → void)
(if (> a 0) (set x a))

;; while loop
(while (< i 10)
  (set i (+ i 1)))

;; block (last expr is the value)
(block
  (var x i32 1)
  (+ x 2))   ;; → 3
```

### Memory

```lisp
(load i32 addr)         ;; read i32 from linear memory
(store i32 addr value)  ;; write i32 to linear memory
```

Memory is automatically exported when load/store are used.

### Function Calls

```lisp
(fn helper ((x i32)) i32 (* x x))
(fn main () i32 (helper 5))  ;; → 25
```

### Imports

```lisp
(import "env" "log" ((x i32)) void)
```

## Examples

See the [`examples/`](examples/) directory:

- **add.sexpr** — minimal function
- **factorial.sexpr** — iterative factorial with while loop
- **fibonacci.sexpr** — fibonacci with if/else and block
- **demo.sexpr** — abs, max, min, sum, is_prime, gcd

## Architecture

```
source.sexpr → Lexer → Parser → AST → Codegen → .wasm binary
```

| File | Purpose |
|------|--------|
| `src/lexer.zig` | Tokenizer (parens, identifiers, numbers) |
| `src/parser.zig` | Recursive descent S-expression parser |
| `src/ast.zig` | AST node types and tree structure |
| `src/codegen.zig` | Direct WASM binary emission |
| `src/wasm.zig` | WASM opcodes, LEB128 encoding, binary helpers |
| `src/main.zig` | CLI entry point + integration tests |

The compiler emits WASM binary directly — no intermediate representation, no WASM text format. A typical function compiles to 40-100 bytes.

## Web Playground

Start the playground server:

```bash
zig build && node web/server.mjs
# Open http://localhost:8000
```

Write S-expressions on the left, hit "Compile & Run" to compile to WASM and execute in the browser.

## Tests

```bash
# Zig unit tests
zig build test

# WASM integration tests (requires Node.js)
node test_wasm.mjs
```

## Design Rationale

See [DESIGN.md](DESIGN.md) for the full design document.

Key insight: Zig's semantics already map almost 1:1 to WebAssembly. Value types, no hidden allocations, explicit control flow — by using Zig's design decisions, the compiler stays tiny while the language remains practical.

## What's Next

Potential additions for future iterations:

- `i64`, `f32`, `f64` literal suffixes
- Struct definitions via memory layout
- Multiple return values
- More WASM opcodes (conversions, extend, wrap)
- Recursive functions
- Data segment initialization
- Better error messages with source locations
- Self-hosting
