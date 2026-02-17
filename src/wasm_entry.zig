//! WASM entry point for the zsexp compiler.
//! Exposes the compiler as a WASM module so it can run in the browser.

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Codegen = @import("codegen.zig").Codegen;

/// Compile source to WASM bytes (same as main.zig's compile).
fn compile(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var parser = Parser.init(allocator, source);
    var tree = try parser.parseProgram();
    var codegen = Codegen.init(allocator, &tree);
    defer codegen.deinit();
    return codegen.generate();
}

// --- Global state for the last compilation result ---
var result_ptr: [*]u8 = undefined;
var result_len: usize = 0;
var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);

/// Allocate `len` bytes in WASM linear memory. Returns pointer as i32.
/// The caller (JS) writes the source text here.
export fn alloc(len: usize) usize {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(slice.ptr);
}

/// Free a previous allocation.
export fn dealloc(ptr: [*]u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

/// Compile the source at `src_ptr[0..src_len]`.
/// Returns 1 on success, 0 on failure.
/// On success, call `get_result_ptr()` and `get_result_len()` to read the output.
export fn do_compile(src_ptr: [*]const u8, src_len: usize) u32 {
    // Reset arena from previous compilation
    arena.deinit();
    arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);

    const allocator = arena.allocator();
    const source = src_ptr[0..src_len];

    const wasm_bytes = compile(allocator, source) catch {
        return 0;
    };

    result_ptr = wasm_bytes.ptr;
    result_len = wasm_bytes.len;
    return 1;
}

/// Get pointer to the compiled WASM bytes.
export fn get_result_ptr() [*]u8 {
    return result_ptr;
}

/// Get length of the compiled WASM bytes.
export fn get_result_len() usize {
    return result_len;
}
