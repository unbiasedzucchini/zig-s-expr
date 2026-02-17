# S-Expr → WASM Compiler: Design Document

## 1. AST Node Types

One tagged union. 14 variants covers the full MVP:

```zig
const NodeIndex = u32; // index into node array (SOA or array-of-structs)

const Node = union(enum) {
    // Literals
    int_literal: i64,       // parsed as i64, narrowed during typeck
    float_literal: f64,     // parsed as f64, narrowed during typeck

    // References
    identifier: []const u8, // variable or function name

    // Expressions
    binop: BinOp,           // (+ a b), (> a b), etc.
    unop: UnOp,             // (- a) for negation, (! a) for logical not
    call: Call,             // (add a b)
    if_expr: IfExpr,        // (if cond then else?) — expression form
    block: []NodeIndex,     // (block e1 e2 ... en) — last expr is value

    // Statements (no value, or value is void)
    local_var: LocalVar,    // (var name type init)
    local_set: LocalSet,    // (set name expr)
    while_loop: While,      // (while cond body...)
    load: Load,             // (load i32 ptr)
    store: Store,           // (store i32 ptr value)

    // Top-level
    fn_def: FnDef,          // (fn name params ret body...)
    export_dir: []const u8, // (export name)
};
```

Sub-structures:

```zig
const BinOp = struct {
    op: enum { add, sub, mul, div_s, div_u, rem_s, rem_u,
               eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u,
               @"and", @"or", shl, shr_s, shr_u, xor },
    lhs: NodeIndex,
    rhs: NodeIndex,
};

const UnOp = struct {
    op: enum { neg, eqz },
    operand: NodeIndex,
};

const Call = struct {
    callee: []const u8,
    args: []NodeIndex,
};

const IfExpr = struct {
    cond: NodeIndex,
    then_body: NodeIndex,     // single expr or block
    else_body: ?NodeIndex,    // if null → statement form (no value)
};

const While = struct {
    cond: NodeIndex,
    body: []NodeIndex,
};

const LocalVar = struct {
    name: []const u8,
    typ: ValType,
    init: NodeIndex,
};

const LocalSet = struct {
    name: []const u8,
    expr: NodeIndex,
};

const Load = struct {
    typ: ValType,
    addr: NodeIndex,
};

const Store = struct {
    typ: ValType,
    addr: NodeIndex,
    value: NodeIndex,
};

const FnDef = struct {
    name: []const u8,
    params: []Param,
    ret: ?ValType,           // null = void
    body: []NodeIndex,       // last expr is return value (if ret != null)
};

const Param = struct {
    name: []const u8,
    typ: ValType,
};

const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
};
```

**Why this is minimal:** No separate "statement" vs "expression" hierarchy.
Nodes that produce no value (var, set, while, store) are tracked by the
codegen, not the AST. The AST is flat — no need for a tree-of-trees.

---

## 2. WASM Binary Format — MVP Sections

A valid .wasm binary needs these bytes:

```
Header:     \0asm\01\00\00\00
Section 1:  Type      (function signatures)
Section 3:  Function  (maps func index → type index)
Section 5:  Memory    (min/max pages) — only if any load/store used
Section 7:  Export    (name → func index or memory)
Section 10: Code      (function bodies)
```

Each section: `section_id(1 byte) | byte_count(LEB128) | contents`

### Section details:

**Type section (id=1)**
```
count: u32 (LEB128)
For each type:
  0x60                           // func type marker
  param_count: u32 (LEB128)
  param_types: [ValType...]      // 0x7F=i32, 0x7E=i64, 0x7D=f32, 0x7C=f64
  result_count: u32 (LEB128)     // 0 or 1 for MVP
  result_types: [ValType...]
```

**Function section (id=3)**
```
count: u32 (LEB128)
For each function:
  type_index: u32 (LEB128)      // index into type section
```

**Memory section (id=5)**
```
count: 1 (LEB128)               // always 1 memory for MVP
  0x00                           // no max
  initial_pages: u32 (LEB128)   // start with 1
```

**Export section (id=7)**
```
count: u32 (LEB128)
For each export:
  name_len: u32 (LEB128)
  name: [u8...]
  kind: u8                       // 0x00=func, 0x02=memory
  index: u32 (LEB128)
```

**Code section (id=10)**
```
count: u32 (LEB128)
For each function:
  body_size: u32 (LEB128)       // byte length of everything below
  local_decl_count: u32 (LEB128)
  For each local group:
    count: u32 (LEB128)          // number of locals of this type
    type: ValType
  <instructions...>
  0x0B                           // end opcode
```

### Key WASM opcodes for MVP:

```
// Control
0x02 block      0x03 loop       0x04 if
0x05 else       0x0B end        0x0C br
0x0D br_if      0x0F return     0x10 call

// Variables
0x20 local.get  0x21 local.set  0x22 local.tee

// Memory
0x28 i32.load   0x29 i64.load   0x2A f32.load   0x2B f64.load
0x36 i32.store  0x37 i64.store  0x38 f32.store  0x39 f64.store

// Constants
0x41 i32.const  0x42 i64.const  0x43 f32.const  0x44 f64.const

// i32 arithmetic
0x6A i32.add    0x6B i32.sub    0x6C i32.mul    0x6D i32.div_s
0x6F i32.rem_s  0x71 i32.and    0x72 i32.or     0x73 i32.xor
0x74 i32.shl    0x75 i32.shr_s

// i32 comparison
0x45 i32.eqz   0x46 i32.eq     0x47 i32.ne     0x48 i32.lt_s
0x4A i32.gt_s   0x4C i32.le_s   0x4E i32.ge_s

// i64 arithmetic — same pattern, starts at 0x7C
// f32 arithmetic — starts at 0x92
// f64 arithmetic — starts at 0xA0

// Drop (discard top of stack)
0x1A drop
```

### LEB128 encoding (critical helper):

```zig
fn encodeLEB128(writer: anytype, value: u32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            try writer.writeByte(byte);
            return;
        }
        try writer.writeByte(byte | 0x80);
    }
}

// Signed LEB128 needed for i32.const, i64.const
fn encodeSLEB128(writer: anytype, value: i64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7F);
        v >>= 7;
        if ((v == 0 and byte & 0x40 == 0) or (v == -1 and byte & 0x40 != 0)) {
            try writer.writeByte(byte);
            return;
        }
        try writer.writeByte(byte | 0x80);
    }
}
```

---

## 3. Type System

### Rules (simple, no inference across functions):

1. **Literals**: `42` → i32 by default. `42L` → i64. `3.14` → f64 by default. `3.14f` → f32.
   Alternatively: all literals default to i32/f64; require explicit casts for i64/f32.

2. **Identifiers**: type is looked up from local/param scope. Always known.

3. **Binary ops**: `(+ a b)` — both operands must have the same type. Result type = operand type.
   Comparisons `(> a b)` always return i32 (WASM has no bool; 0/1 i32).

4. **If-expression**: `(if cond then else)` — cond must be i32. then/else must have same type.
   That type becomes the if-expression's type.

5. **If-statement** (no else): `(if cond body)` — body value is dropped. Expression type is void.

6. **Block**: type of last expression. `(block (var x i32 0) (+ x 1))` → i32.

7. **Function call**: return type comes from function's declared signature.

8. **var/set/store/while**: void. If they appear as the last expr in a function with
   a return type, that's a compile error.

### Type checking implementation:

```zig
/// Returns the ValType of an expression node, or null for void.
fn typeOf(node: Node, scope: *Scope) ?ValType { ... }
```

Single-pass: type check during codegen, or as a separate pass that annotates
each NodeIndex with its resolved type. **Recommendation: separate pass.** It's
cleaner and the cost is negligible for MVP.

---

## 4. Local Variable Handling

WASM locals are indexed. Params come first, then declared locals:

```
Param 0: a i32  → local.get 0
Param 1: b i32  → local.get 1
Local 0: x i32  → local.get 2   (index = param_count + declaration_order)
Local 1: y i64  → local.get 3
```

### Data structure:

```zig
const Scope = struct {
    locals: std.StringHashMap(LocalInfo),
    local_count: u32,
    param_count: u32,

    const LocalInfo = struct {
        index: u32,
        typ: ValType,
    };

    fn addParam(self: *Scope, name: []const u8, typ: ValType) !void {
        try self.locals.put(name, .{
            .index = self.param_count,
            .typ = typ,
        });
        self.param_count += 1;
        self.local_count += 1;
    }

    fn addLocal(self: *Scope, name: []const u8, typ: ValType) !void {
        try self.locals.put(name, .{
            .index = self.local_count,
            .typ = typ,
        });
        self.local_count += 1;
    }

    fn resolve(self: *Scope, name: []const u8) !LocalInfo {
        return self.locals.get(name) orelse error.UndefinedVariable;
    }
};
```

**Key insight:** You need to collect ALL locals in a function body before emitting
the code section entry, because the local declaration block comes first in the
WASM binary. Two options:

- **Option A (recommended):** Two-pass per function. Pass 1: walk AST, collect
  all `var` declarations and assign indices. Pass 2: emit bytecode.
- **Option B:** Emit code to a temporary buffer. Prepend local declarations after.

Option A is simpler. The local-collection pass is trivial.

---

## 5. Key Design Decisions

### `if` is an expression when it has `else`, a statement when it doesn't.

```lisp
;; Expression — both branches produce i32, whole thing produces i32
(var x i32 (if (> a 0) a (- 0 a)))

;; Statement — no else, body value is dropped
(if (> a 0) (set x a))
```

WASM directly supports this: `if (result i32) ... else ... end` vs `if ... end`.

### Blocks / multiple expressions in function bodies

A function body is an implicit block. The last expression's value is the return value.

```lisp
(fn abs ((x i32)) i32
  (if (< x 0)
    (- 0 x)
    x))

(fn example ((x i32)) i32
  (var y i32 (+ x 1))     ;; void — emit, then drop nothing (void doesn't push)
  (set y (* y 2))          ;; void
  y)                       ;; i32 — left on stack as return value
```

**Codegen rule for blocks:** For each expression except the last: emit it, then
emit `drop` if it produces a value. For the last expression: emit it, leave
value on stack. This works because WASM is stack-based.

### Operator dispatch by type

`+` maps to different WASM opcodes depending on operand type:

| Op | i32 | i64 | f32 | f64 |
|----|-----|-----|-----|-----|
| +  | i32.add | i64.add | f32.add | f64.add |
| -  | i32.sub | i64.sub | f32.sub | f64.sub |
| *  | i32.mul | i64.mul | f32.mul | f64.mul |
| /  | i32.div_s | i64.div_s | f32.div | f64.div |
| >  | i32.gt_s | i64.gt_s | f32.gt | f64.gt |
| ...| ... | ... | ... | ... |

### `while` codegen pattern

```lisp
(while (< i 10) body...)
```
Compiles to:
```wasm
block $break          ;; br 1 exits
  loop $continue      ;; br 0 re-enters
    <cond>
    i32.eqz
    br_if $break      ;; exit if cond is false
    <body...>         ;; drop values from non-last body exprs
    br $continue      ;; loop back
  end
end
```
Note: while always produces void. Every expression in the body gets `drop`ped.

---

## 6. Compiler Pipeline

```
source: []const u8
    │
    ▼
┌──────────┐   Tokenize into: ( ) identifier number
│  Lexer   │   No keywords — `fn`, `if`, `var` are just identifiers.
└──────────┘   Tokens: enum { lparen, rparen, ident, int_lit, float_lit, eof }
    │
    ▼
┌──────────┐   Recursive descent. Trivial grammar:
│  Parser  │   expr = atom | '(' head expr* ')'
└──────────┘   Head determines node type.
    │
    ▼
┌──────────┐   Walk AST, resolve types, collect locals.
│ Analyzer │   Produces: typed AST + per-function scope tables.
└──────────┘   Errors: type mismatch, undefined variable, etc.
    │
    ▼
┌──────────┐   Walk typed AST, emit WASM bytecode.
│  Codegen │   Uses ArrayList(u8) as output buffer.
└──────────┘   One pass over each function.
    │
    ▼
  .wasm binary
```

### File structure:

```
src/
  main.zig          Entry point — read file, run pipeline, write .wasm
  lexer.zig         Tokenizer
  parser.zig        S-expr → AST
  ast.zig           Node types (the union + sub-structs above)
  analyzer.zig      Type checking + local collection
  codegen.zig       AST → WASM binary
  wasm.zig          WASM binary helpers (LEB128, section builders, opcodes)
build.zig
```

---

## 7. Testing Strategy

The fastest feedback loop:

1. **Unit test codegen** by comparing emitted bytes against hand-assembled WASM.
2. **Round-trip test**: compile .sexpr → .wasm, run with `wasmtime` or Node.js,
   check output. Example:

```zig
test "add function" {
    const wasm = try compile("(fn add ((a i32) (b i32)) i32 (+ a b)) (export add)");
    // The WASM magic header
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }, wasm[0..8]);
    // Or: write to tmp file, shell out to wasmtime
}
```

---

## 8. Gotchas & Traps

1. **WASM block types**: `if`, `block`, `loop` need a block type byte.
   - `0x40` = void (no result)
   - `0x7F` = i32, etc. (produces one value)
   - Get this wrong → wasm validation failure.

2. **LEB128 for section sizes**: You won't know the size until after encoding.
   **Pattern**: encode contents to a temp buffer, then write `len(temp)` as LEB128,
   then write temp. Use `std.ArrayList(u8)` for this.

3. **Stack discipline**: Every non-void expression pushes exactly one value.
   `drop` any values you don't consume. WASM validators will reject modules
   with unbalanced stacks.

4. **Memory alignment in load/store**: WASM load/store take an alignment hint
   and offset, both LEB128-encoded after the opcode. For MVP, use
   `align=2` (4-byte natural) and `offset=0` for i32. Don't forget these bytes.

   ```
   i32.load  alignment:u32  offset:u32   →  0x28 0x02 0x00
   i32.store alignment:u32  offset:u32   →  0x36 0x02 0x00
   ```
   Alignment is `log2(bytes)`: i32→2, i64→3, f32→2, f64→3.

5. **Function indices**: functions are indexed in definition order starting at 0
   (no imports in MVP, so no offset). The function→name map is needed for
   resolving `call` instructions.

6. **De-duplicate type signatures**: If `add` and `sub` both have type
   `(i32, i32) → i32`, they should share one entry in the type section.
   Use a hashmap keyed on `(params, return_type)` → `type_index`.
