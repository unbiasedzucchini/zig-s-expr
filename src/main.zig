const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Codegen = @import("codegen.zig").Codegen;

pub fn compile(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var parser = Parser.init(allocator, source);
    var tree = try parser.parseProgram();
    var codegen = Codegen.init(allocator, &tree);
    defer codegen.deinit();
    return codegen.generate();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: zsexp <input.sexpr> [output.wasm]\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = if (args.len >= 3) args[2] else "out.wasm";

    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, 1024 * 1024);
    defer allocator.free(source);

    const wasm_bytes = compile(allocator, source) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Compilation error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(wasm_bytes);

    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = wasm_bytes });

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Compiled {s} -> {s} ({} bytes)\n", .{ input_path, output_path, wasm_bytes.len });
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("wasm.zig");
    _ = @import("codegen.zig");
}

fn testCompile(source: []const u8) !struct { bytes: []u8, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    const bytes = compile(allocator, source) catch |e| {
        arena.deinit();
        return e;
    };
    return .{ .bytes = bytes, .arena = arena };
}

test "compile add function" {
    var r = try testCompile("(fn add ((a i32) (b i32)) i32 (+ a b)) (export add)");
    defer r.arena.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D }, r.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x00, 0x00 }, r.bytes[4..8]);
    try std.testing.expect(r.bytes.len > 20);
}

test "compile with locals" {
    var r = try testCompile(
        \\(fn double ((x i32)) i32
        \\  (var y i32 (+ x x))
        \\  y)
        \\(export double)
    );
    defer r.arena.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D }, r.bytes[0..4]);
}

test "compile with if" {
    var r = try testCompile(
        \\(fn max ((a i32) (b i32)) i32
        \\  (if (> a b) a b))
        \\(export max)
    );
    defer r.arena.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D }, r.bytes[0..4]);
}

test "compile with while" {
    var r = try testCompile(
        \\(fn sum_to ((n i32)) i32
        \\  (var i i32 0)
        \\  (var acc i32 0)
        \\  (while (< i n)
        \\    (set acc (+ acc i))
        \\    (set i (+ i 1)))
        \\  acc)
        \\(export sum_to)
    );
    defer r.arena.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D }, r.bytes[0..4]);
}
