//! WASM entry point for the zsexp compiler (wasmexec contract).
//!
//! Contract:
//!   - Host writes source text at 0x10000, calls run(0x10000, len)
//!   - run() returns pointer to [output_len: u32 LE][output_bytes...]
//!   - Exports: run, memory

const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Codegen = @import("codegen.zig").Codegen;

fn compile(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var parser = Parser.init(allocator, source);
    var tree = try parser.parseProgram();
    var codegen = Codegen.init(allocator, &tree);
    defer codegen.deinit();
    return codegen.generate();
}

const OUTPUT_BASE: usize = 0x20000;

var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);

export fn run(input_ptr: [*]const u8, input_len: u32) u32 {
    // Reset arena from any previous call
    arena.deinit();
    arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    const allocator = arena.allocator();

    const source = input_ptr[0..input_len];

    const wasm_bytes = compile(allocator, source) catch |err| {
        // On error, write error name as output
        const prefix = "error: ";
        const name = @errorName(err);
        const total = prefix.len + name.len;
        const out: [*]u8 = @ptrFromInt(OUTPUT_BASE);
        std.mem.writeInt(u32, out[0..4], @intCast(total), .little);
        @memcpy(out[4 .. 4 + prefix.len], prefix);
        @memcpy(out[4 + prefix.len .. 4 + total], name);
        return @intCast(OUTPUT_BASE);
    };

    // Write [u32 LE length][wasm bytes...] at OUTPUT_BASE
    const out: [*]u8 = @ptrFromInt(OUTPUT_BASE);
    std.mem.writeInt(u32, out[0..4], @intCast(wasm_bytes.len), .little);
    @memcpy(out[4 .. 4 + wasm_bytes.len], wasm_bytes);

    return @intCast(OUTPUT_BASE);
}
